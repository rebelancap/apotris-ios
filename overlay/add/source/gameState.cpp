// Single-slot suspend-save for an in-progress game. See gameState.hpp.
//
// The whole point of the file is that capture and restore must agree on the
// field order forever, so there is exactly ONE description of the layout:
// visitGame() is a template instantiated with a Writer and a Reader that
// expose the same call signatures. Adding a field means touching one line,
// and it is impossible to add it to the writer but forget the reader.
//
// Access to Game's private handling/RNG state comes from the one-line
// `friend struct GameStateIO;` added by overlay patch 0014 — without it a
// resumed game would keep its board but lose DAS charge, lock delay, the
// active bag, grade progress and the piece-drought counters.

#include "gameState.hpp"

// def.h pulls blockEngine.hpp, save.h and platform.hpp — the latter is what
// routes log() to liba_pc.h's std::cout sink under IOS (freopen'd to
// Documents/apotris.log by liba_ios.mm).
#include "def.h"

#include <cstring>
#include <list>
#include <tuple>
#include <type_traits>

using BlockEngine::Connection;
using BlockEngine::Drop;
using BlockEngine::Game;
using BlockEngine::Garbage;
using BlockEngine::Options;
using BlockEngine::Pawn;
using BlockEngine::Score;
using BlockEngine::Stats;
using BlockEngine::Timestamp;

namespace {

constexpr char kMagic[8] = {'A', 'P', 'O', 'S', 'A', 'V', 'E', '1'};
constexpr uint32_t kVersion = 1;

// Nothing in Game legitimately grows past this; a larger count means a corrupt
// blob, and we refuse it rather than trying to allocate it.
constexpr uint32_t kMaxListLen = 65536;

// Compact identity of a run, logged on both sides of a suspend so a resume can
// be checked across a process restart without trusting pixels.
std::string fingerprint(const Game& g, uint32_t boardHash) {
    return "mode=" + std::to_string(g.gameMode) +
           " score=" + std::to_string(g.score) +
           " lvl=" + std::to_string(g.level) +
           " lines=" + std::to_string(g.linesCleared) +
           " t=" + std::to_string(g.inGameTimer) +
           " pieces=" + std::to_string(g.pieceCounter) +
           " held=" + std::to_string(g.held) +
           " board=" + std::to_string(boardHash);
}

uint32_t fnv1a(const uint8_t* p, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 16777619u;
    }
    return h;
}

struct Writer {
    std::vector<uint8_t>* out;
    bool ok = true;

    void bytes(const void* p, size_t n) {
        const uint8_t* c = static_cast<const uint8_t*>(p);
        out->insert(out->end(), c, c + n);
    }

    // Symmetric with Reader::raw by design: both are `bytes(&v, sizeof v)`,
    // and only the direction of `bytes` differs.
    template <class T> void raw(T& v) {
        static_assert(std::is_trivially_copyable<T>::value,
                      "raw() is for trivially copyable state only — give the "
                      "type an explicit visit() overload instead");
        bytes(&v, sizeof(T));
    }

    template <class C, class F, class MK> void list(C& c, F fn, MK) {
        uint32_t n = static_cast<uint32_t>(c.size());
        raw(n);
        for (auto& e : c)
            fn(*this, e);
    }

    // `unstable` holds pointers into `connections`, so it travels as indices.
    // Both lists are passed in rather than reached for through Game: only
    // GameStateIO is a friend, and these archives are not it.
    void unstableList(std::list<Connection>& connections,
                      std::list<Connection*>& unstable) {
        uint32_t n = static_cast<uint32_t>(unstable.size());
        raw(n);
        for (const Connection* target : unstable) {
            uint32_t idx = 0, i = 0;
            for (const Connection& c : connections) {
                if (&c == target) {
                    idx = i;
                    break;
                }
                i++;
            }
            raw(idx);
        }
    }
};

struct Reader {
    const uint8_t* p = nullptr;
    size_t left = 0;
    bool ok = true;

    void bytes(void* dst, size_t n) {
        if (!ok || left < n) {
            ok = false;
            return;
        }
        memcpy(dst, p, n);
        p += n;
        left -= n;
    }

    template <class T> void raw(T& v) {
        static_assert(std::is_trivially_copyable<T>::value,
                      "raw() is for trivially copyable state only — give the "
                      "type an explicit visit() overload instead");
        bytes(&v, sizeof(T));
    }

    template <class C, class F, class MK> void list(C& c, F fn, MK make) {
        uint32_t n = 0;
        raw(n);
        if (!ok || n > kMaxListLen) {
            ok = false;
            return;
        }
        c.clear();
        for (uint32_t i = 0; i < n && ok; i++) {
            auto e = make();
            fn(*this, e);
            c.push_back(e);
        }
    }

    void unstableList(std::list<Connection>& connections,
                      std::list<Connection*>& unstable) {
        uint32_t n = 0;
        raw(n);
        if (!ok || n > kMaxListLen) {
            ok = false;
            return;
        }
        unstable.clear();
        for (uint32_t i = 0; i < n && ok; i++) {
            uint32_t idx = 0;
            raw(idx);
            if (!ok || idx >= connections.size()) {
                ok = false;
                return;
            }
            auto it = connections.begin();
            std::advance(it, idx);
            unstable.push_back(&*it);
        }
    }
};

// Types with user-declared copy constructors are not trivially copyable, so
// they get spelled out rather than memcpy'd.

template <class Ar> void visit(Ar& ar, Drop& d) {
    ar.raw(d.on);
    ar.raw(d.startX);
    ar.raw(d.endX);
    ar.raw(d.startY);
    ar.raw(d.endY);
    ar.raw(d.rawEndY);
    ar.raw(d.x);
    ar.raw(d.y);
    ar.raw(d.dx);
    ar.raw(d.dy);
    ar.raw(d.piece);
    ar.raw(d.rotation);
    ar.raw(d.rotating);
}

template <class Ar> void visit(Ar& ar, Score& s) {
    ar.raw(s.linesCleared);
    ar.raw(s.score);
    ar.raw(s.combo);
    ar.raw(s.isTSpin);
    ar.raw(s.isPerfectClear);
    ar.raw(s.isBackToBack);
    ar.raw(s.isDifficult);
    ar.raw(s.cascadeComplexity);
    visit(ar, s.drop);
}

template <class Ar> void visit(Ar& ar, Stats& s) {
    ar.raw(s.clears);
    ar.raw(s.tspins);
    ar.raw(s.perfectClears);
    ar.raw(s.maxStreak);
    ar.raw(s.maxCombo);
    ar.raw(s.holds);
    ar.raw(s.maxZonedLines);
    ar.raw(s.maxCascade);
    ar.raw(s.secretGrade);
}

template <class Ar> void visit(Ar& ar, Pawn& p) {
    ar.raw(p.x);
    ar.raw(p.y);
    ar.raw(p.type);
    ar.raw(p.current);
    ar.raw(p.rotation);
    ar.raw(p.board);
    ar.raw(p.boardLowest);
    ar.raw(p.heighest);
    ar.raw(p.lowestBlock);
    ar.raw(p.lowest);
    ar.raw(p.big);
}

template <class Ar> void visit(Ar& ar, BlockEngine::Tuning& t) {
    ar.raw(t.das);
    ar.raw(t.arr);
    ar.raw(t.sfr);
    ar.raw(t.dropProtection);
    ar.raw(t.directionalDas);
    ar.raw(t.delaySoftDrop);
    ar.raw(t.ihs);
    ar.raw(t.irs);
    ar.raw(t.initialType);
}

template <class Ar> void visitOptions(Ar& ar, Options& o) {
    int32_t mode = static_cast<int32_t>(o.mode);
    ar.raw(mode);
    o.mode = static_cast<BlockEngine::Modes>(mode);
    ar.raw(o.goal);
    ar.raw(o.level);
    visit(ar, o.tuning);
    ar.raw(o.trainingMode);
    ar.raw(o.bigMode);
    ar.raw(o.bTypeHeight);
    ar.raw(o.subMode);
    ar.raw(o.rotationSystem);
    ar.raw(o.randomizer);
}

} // namespace

namespace BlockEngine {

// Befriended by patch 0014 so the private handling state is reachable.
struct GameStateIO {
    template <class Ar> static void visitGame(Ar& ar, Game& g) {
        // --- private: handling, timing and RNG bookkeeping ---
        ar.raw(g.bigBag);
        ar.raw(g.maxDas);
        ar.raw(g.das);
        ar.raw(g.arr);
        ar.raw(g.arrCounter);
        ar.raw(g.softDropCounter);
        ar.raw(g.maxSoftDrop);
        ar.raw(g.softDropSpeed);
        ar.raw(g.softDropRepeatTimer);
        ar.raw(g.lockMoveCounter);
        ar.raw(g.left);
        ar.raw(g.right);
        ar.raw(g.down);
        ar.raw(g.lastMoveRotation);
        ar.raw(g.lastMoveDx);
        ar.raw(g.lastMoveDy);
        ar.raw(g.finesseCounter);
        visit(ar, g.lastDrop);
        ar.raw(g.dropProtection);
        ar.raw(g.directionCancel);
        ar.raw(g.dropLockTimer);
        ar.raw(g.dropLockMax);
        ar.raw(g.specialTspin);
        ar.raw(g.pieceHistory);
        ar.raw(g.gracePeriod);
        ar.raw(g.section);
        ar.raw(g.sectionStart);
        ar.raw(g.previousSectionTime);
        ar.raw(g.internalGrade);
        ar.raw(g.gradePoints);
        ar.raw(g.cool);
        ar.raw(g.regret);
        ar.raw(g.decayTimer);
        ar.raw(g.stopLockReset);
        ar.raw(g.fromLockHold);
        ar.raw(g.fromLockRotate);
        ar.raw(g.pieceDrought);
        ar.raw(g.delaySoftDrop);
        ar.raw(g.ihs);
        ar.raw(g.irs);
        ar.raw(g.initialType);
        ar.raw(g.rotates);
        ar.raw(g.zoneExit);
        ar.raw(g.sonicDrop);
        ar.raw(g.bag);
        ar.raw(g.historyList);
        ar.list(
            g.connections,
            [](Ar& a, Connection& c) { a.raw(c); },
            [] { return Connection(0, 0, 0); });
        ar.unstableList(g.connections, g.unstable);

        // --- public: board and run state ---
        ar.raw(g.randomSeed);
        ar.raw(g.lengthX);
        ar.raw(g.lengthY);
        ar.raw(g.board);
        ar.raw(g.bitboard);
        ar.raw(g.columnHeights);
        visit(ar, g.pawn);
        ar.raw(g.held);
        ar.raw(g.speed);
        ar.raw(g.speedCounter);
        ar.raw(g.linesCleared);
        ar.raw(g.level);
        ar.raw(g.score);
        ar.raw(g.comboCounter);
        ar.raw(g.lineClearArray);
        ar.raw(g.clearLock);
        ar.raw(g.lost);
        ar.raw(g.gameMode);
        // g.sounds is intentionally not carried: the flags are per-frame sound
        // triggers, and replaying them on resume would fire a stale clear/
        // levelup sting. A fresh Game zeroes them.
        visit(ar, g.previousClear);
        ar.raw(g.timer);
        // g.refresh is intentionally not carried, for the same reason as
        // g.sounds: it is a redraw request the renderer consumes each frame,
        // not game state. restore() forces a full redraw instead.
        ar.raw(g.won);
        ar.raw(g.goal);
        ar.raw(g.finesseFaults);
        ar.raw(g.garbageCleared);
        ar.raw(g.garbageHeight);
        ar.raw(g.pushDir);
        ar.raw(g.b2bCounter);
        ar.raw(g.bagCounter);
        ar.raw(g.linesSent);
        ar.raw(g.pieceCounter);
        ar.raw(g.previousKey);
        ar.raw(g.softDrop);
        ar.raw(g.canHold);
        ar.raw(g.holding);
        ar.raw(g.trainingMode);
        ar.raw(g.seed);
        ar.raw(g.initSeed);
        ar.raw(g.initialLevel);
        ar.raw(g.eventTimer);
        ar.raw(g.dropping);
        ar.raw(g.entryDelay);
        ar.raw(g.areMax);
        ar.raw(g.lineAre);
        ar.raw(g.maxClearDelay);
        ar.raw(g.bTypeHeight);
        visit(ar, g.statTracker);
        ar.raw(g.subMode);
        ar.raw(g.zoneCharge);
        ar.raw(g.zoneTimer);
        ar.raw(g.zonedLines);
        ar.raw(g.zoneScore);
        ar.raw(g.zoneStart);
        ar.raw(g.fullZone);
        ar.raw(g.inversion);
        ar.raw(g.grade);
        ar.raw(g.coolCount);
        ar.raw(g.regretCount);
        ar.raw(g.rotationSystem);
        ar.raw(g.randomizer);
        ar.raw(g.maxLockTimer);
        ar.raw(g.lockTimer);
        ar.raw(g.disappearTimers);
        ar.raw(g.disappearing);
        ar.raw(g.creditGrade);
        ar.raw(g.eventLock);
        ar.raw(g.finesseStreak);
        ar.raw(g.inGameTimer);
        ar.raw(g.stackHeight);
        ar.raw(g.replayTimerSections);
        ar.raw(g.boardOffset);
        ar.raw(g.activePiece);
        ar.raw(g.toEndZone);
        ar.raw(g.verticalKick);
        ar.raw(g.verticalKickMax);
        ar.raw(g.replayElligible);
        ar.raw(g.fullLine);
        ar.raw(g.peek);
        ar.raw(g.deathGarbageCounter);
        ar.raw(g.towerScrollCount);
        ar.raw(g.towerClearingPhase);
        ar.raw(g.towerMediumClearing);
        ar.raw(g.towerMediumTimer);
        ar.raw(g.towerMediumDelay);
        ar.raw(g.cascadeTimer);
        ar.raw(g.cascadeComplexity);
        ar.raw(g.queue);
        ar.raw(g.moveHistory);
        ar.raw(g.previousBest);
        ar.list(
            g.linesToClear, [](Ar& a, int& v) { a.raw(v); }, [] { return 0; });
        ar.list(
            g.attackQueue, [](Ar& a, Garbage& v) { a.raw(v); },
            [] { return Garbage(0, 0); });
        ar.list(
            g.garbageQueue, [](Ar& a, Garbage& v) { a.raw(v); },
            [] { return Garbage(0, 0); });
        ar.list(
            g.toDisappear,
            [](Ar& a, std::tuple<uint8_t, uint8_t>& v) {
                a.raw(std::get<0>(v));
                a.raw(std::get<1>(v));
            },
            [] { return std::tuple<uint8_t, uint8_t>(0, 0); });
        ar.list(
            g.replay, [](Ar& a, Timestamp& v) { a.raw(v); },
            [] { return Timestamp(); });
    }
};

} // namespace BlockEngine

// Tripwire. Upstream adding a Game field is silent data loss — a resumed run
// would quietly drop it — so make the build fail instead and force whoever
// re-pins upstream to extend visitGame(). If this fires: add the new field(s)
// to visitGame in declaration order, bump kVersion, then update this number.
static_assert(sizeof(Game) == 4176,
              "BlockEngine::Game changed size — review gameState.cpp's "
              "visitGame() for fields added or removed upstream, then update "
              "this assertion (see overlay patch 0014).");

namespace GameState {

bool eligible() {
    if (game == nullptr)
        return false;
    if (demo || replaying || multiplayer)
        return false;
    if (game->lost || game->won)
        return false;
    // NO_MODE is the attract-demo engine; BATTLE runs a second Game (botGame)
    // that this snapshot does not carry.
    if (game->gameMode == BlockEngine::NO_MODE ||
        game->gameMode == BlockEngine::BATTLE)
        return false;
    return previousGameOptions != nullptr;
}

std::vector<uint8_t> capture() {
    std::vector<uint8_t> blob;
    if (!eligible())
        return blob;

    std::vector<uint8_t> payload;
    Writer w{&payload};
    Options opts = *previousGameOptions;
    visitOptions(w, opts);
    // The seed startGame() should be handed on the way back. Every RNG field
    // is overwritten by visitGame() below, so this only has to be the value
    // the run was born with, not a live one.
    int32_t bornSeed = game->initSeed;
    w.raw(bornSeed);
    BlockEngine::GameStateIO::visitGame(w, *game);
    if (!w.ok)
        return blob;

    Info info;
    info.mode = game->gameMode;
    info.subMode = game->subMode;
    info.score = static_cast<int32_t>(game->score);
    info.level = game->level;
    info.lines = game->linesCleared;
    info.inGameTimer = game->inGameTimer;

    uint32_t version = kVersion;
    uint32_t gameSize = static_cast<uint32_t>(sizeof(Game));
    uint32_t len = static_cast<uint32_t>(payload.size());
    uint32_t sum = fnv1a(payload.data(), payload.size());

    Writer h{&blob};
    blob.insert(blob.end(), kMagic, kMagic + sizeof(kMagic));
    h.raw(version);
    h.raw(gameSize);
    h.raw(info);
    h.raw(len);
    h.raw(sum);
    blob.insert(blob.end(), payload.begin(), payload.end());
    log("suspend-save: captured " + std::to_string(blob.size()) + "B " +
        fingerprint(*game, fnv1a((const uint8_t*)game->board,
                                 sizeof(game->board))));
    return blob;
}

namespace {

// Shared header parse. On success `body` points at the verified payload.
bool parseHeader(const std::vector<uint8_t>& blob, Info& info, Reader& body) {
    const size_t headerLen =
        sizeof(kMagic) + sizeof(uint32_t) * 2 + sizeof(Info) + sizeof(uint32_t) * 2;
    if (blob.size() < headerLen)
        return false;
    if (memcmp(blob.data(), kMagic, sizeof(kMagic)) != 0)
        return false;

    Reader h{blob.data() + sizeof(kMagic), blob.size() - sizeof(kMagic)};
    uint32_t version = 0, gameSize = 0, len = 0, sum = 0;
    h.raw(version);
    h.raw(gameSize);
    h.raw(info);
    h.raw(len);
    h.raw(sum);
    if (!h.ok || version != kVersion || gameSize != sizeof(Game))
        return false;
    if (h.left != len)
        return false;
    if (fnv1a(h.p, len) != sum)
        return false;

    body = h;
    return true;
}

} // namespace

bool inspect(const std::vector<uint8_t>& blob, Info& info) {
    Reader body;
    return parseHeader(blob, info, body);
}

bool restore(const std::vector<uint8_t>& blob) {
    Info info;
    Reader r;
    if (!parseHeader(blob, info, r)) {
        log("suspend-save: header rejected");
        return false;
    }

    Options opts;
    visitOptions(r, opts);
    int32_t bornSeed = 0;
    r.raw(bornSeed);
    if (!r.ok) {
        log("suspend-save: options truncated");
        return false;
    }

    // Let upstream build the run (mode setup, tuning, music, achievements),
    // then overwrite the engine state on top of it.
    startGame(opts, bornSeed);
    // startGame counts a fresh attempt; resuming one is not a new game.
    if (!demo && savefile != nullptr)
        savefile->stats.gamesStarted--;

    BlockEngine::GameStateIO::visitGame(r, *game);
    if (!r.ok || r.left != 0) {
        log("suspend-save: payload did not deserialize cleanly");
        return false;
    }

    game->resetSounds();
    game->resetRefresh();
    game->refresh = 2;
    log("suspend-save: restored " + std::to_string(blob.size()) + "B " +
        fingerprint(*game, fnv1a((const uint8_t*)game->board,
                                 sizeof(game->board))));
    return true;
}

} // namespace GameState
