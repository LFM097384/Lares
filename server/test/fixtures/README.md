# 测试专用夹具 —— TEST ONLY

`fake-apns-TEST-ONLY.{cert,key}.pem`:自签 EC P-256 证书(CN=127.0.0.1,SAN IP:127.0.0.1,有效期 100 年),
**只**给 `test/push.mjs` 里的假 APNs(`http2.createSecureServer`)做 TLS 用。

为什么提交进仓库而不是测试时现生成:Node 不能原生生成 X.509,
而 CI / `node:22-alpine` 里不保证有 `openssl`。这把私钥不保护任何东西 ——
服务端只有在同时设了 `LARES_APNS_HOST_OVERRIDE` 与 `LARES_APNS_INSECURE_TLS=1` 时才会接受自签证书,
生产环境两者都不设。**不要在任何其它地方使用这对钥匙。**

重新生成(需 openssl):

    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout fake-apns-TEST-ONLY.key.pem -out fake-apns-TEST-ONLY.cert.pem \
      -days 36500 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1"
