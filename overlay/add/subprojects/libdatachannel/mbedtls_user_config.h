/* Appended to mbedTLS's default config (MBEDTLS_USER_CONFIG_FILE).
 * libdatachannel's DtlsTransport unconditionally configures DTLS-SRTP
 * protection profiles under mbedTLS 3.x (src/impl/dtlstransport.cpp), even for
 * data-only channels, so this option must be enabled or the build fails with
 * undefined mbedtls_ssl_srtp_* symbols. */
#define MBEDTLS_SSL_DTLS_SRTP
