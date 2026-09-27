/**
 * FCM 서명 테스트용 버리는 RSA 키쌍(2048bit).
 *
 *   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out key.pem
 *   openssl pkey -in key.pem -pubout
 *
 * 이 키는 이 저장소의 테스트 안에서만 쓴다. 어떤 구글 프로젝트에도 등록돼 있지 않고,
 * 어떤 서비스의 자격증명도 아니다. 하는 일은 하나뿐이다: 우리가 만든 OAuth JWT를
 * 대응하는 공개키로 "실제로" 검증해서 서명 경로가 살아 있음을 증명하는 것.
 * (그래서 개인키가 파일에 그대로 들어 있다 - 유출될 비밀이 아니다.)
 */

/** 가짜 서비스 계정의 private_key. */
export const TEST_PRIVATE_KEY_PEM = `-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCzC971LyfGbOqU
Jm+pJh/ApWTgMCE66aii7tbU9iuo4eHjF8gUFFLSnBfIOyRPKPcnH8K8Uat8sQzo
fkuyYGW7enG36YgeW4+vOBll9BE1o9pA0AzaDYu+9LSHuaTJEZvTFWHKudZ+PhPw
pB93uQ03VtJE1Z8X/aBK8/2x86D19GMUPdX+0KnH2TdMb+L3XoT08+hBdjSxZ+qa
BcS7Oaklf8WC4CDO6N/A0iNVmbBB1chvjqN2htNLPqlyToTmHDwg7/qhC7l6ASrW
Sov+fPFKkH/6Z4oMorbS+a7iRebHWHw1dT4N3LMf8AIM0ExKs99Bl4k5FBII7Xp0
Uz6F4kJdAgMBAAECggEAJpzRRPQZ8ldr0W5ml0ZzA5NHqXeHuxJH/XdfmkbKjJ3G
Hrjyu63UXLowAM0MXAv8HRJi50T/pCD0pTETdxEF74QNAToaUl2xo3qIM64KhhRj
jaWwl9fjAtf4FOsqx/gFsGSElfk08j3GBBgI90NPv9b3+sNND5nxVyi+VgGx/UiN
/Q2Rg2ZFs3hKe1E8b7e3Ojiofi/L0UWN/aKe+5LcgmBxDK1Z+pOXSYPxDH0vW2zT
DsH1fE9gCHUuwYnpxYIvSrYjzTMdYPejakGEvpBqjOQiWqRgoCQwprlz/d3siqfk
xD01slghgAWngxxc3tkaqG1qZI18lCts39KUjpCBSwKBgQDmREgtNtE74/302zWH
zE7SqeAXev9LiqTMh0bA/FiV7oDW1IfYY2LzhkOEhV+l4ExfwQV1J/yxsfZoFmxi
+uCgOvlhyihIWJmF96J4DxUyCQLtKoE6MVZ5GNFhpl+OHWr3QUx2j6xFn2cr9bir
Deszu7V9a2ExAVEqi2z0mO8NowKBgQDHDjjUhAFm2Ummaj3PpQgNw9kNl6oSIX5d
ZuEFBzK6GDa0HpxpfuJ5PIlNk+7yZbxVewNd4n+CxNlhva5usTVq/r46qe76fSfq
Y6unugX66indtqC53NKZFzYHBbBqo7UJDveKTmaydJq0QmcZ1sfvsyC/W7KfgM33
1wOIzV5v/wKBgChsWkNduTOLXbzLcsVJL5k56zYUCJdJWo7xPJGKez6u5P1RyBtL
r0ZTDq1IALeM/btdlkiv4WOMe1ZggVyK8D4QvFDXfWTd8O2cwG/VLgJfpJzf9lmx
6Z1Opws+es3nCi0n0HWL2VFLn4APHgEha2XkkQLYg/JnaclPOqxh4K2DAoGAZU5d
qfrM49UuYJ2te6JYKPlF3F8V1UhqkYqsduyk6oUsQhtaK27CQEWI84yYjZEtequy
mPOPRbR9lfr9baSOtTeVBTI7SAyuZeH4GNLZ/Et0pzwtLKqwG+3uN0Cz+nH6zvNp
FGC2b5hcq+Unp8Th2KJnxjwa+oaJTNuHFva+W20CgYAf4BfJ0otUMAQZ4GXgd3Sg
6/j47JrZIU0bF8gVsGW2va+Od/MjVedJEr/t8Y0ZY0oB24RkYGVpzeUZDYjcqeAW
3dovx1/s4B8OPEBkn27/EryZvjUXCTgS4CaRZFB2e2HIwZtg5x237NilryQeIgeN
Y5p33bvgwOwa/bpsIynemA==
-----END PRIVATE KEY-----`;

/** 위 개인키의 공개키. 테스트가 crypto.subtle.verify로 JWT 서명을 검증할 때 쓴다. */
export const TEST_PUBLIC_KEY_PEM = `-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAswve9S8nxmzqlCZvqSYf
wKVk4DAhOumoou7W1PYrqOHh4xfIFBRS0pwXyDskTyj3Jx/CvFGrfLEM6H5LsmBl
u3pxt+mIHluPrzgZZfQRNaPaQNAM2g2LvvS0h7mkyRGb0xVhyrnWfj4T8KQfd7kN
N1bSRNWfF/2gSvP9sfOg9fRjFD3V/tCpx9k3TG/i916E9PPoQXY0sWfqmgXEuzmp
JX/FguAgzujfwNIjVZmwQdXIb46jdobTSz6pck6E5hw8IO/6oQu5egEq1kqL/nzx
SpB/+meKDKK20vmu4kXmx1h8NXU+DdyzH/ACDNBMSrPfQZeJORQSCO16dFM+heJC
XQIDAQAB
-----END PUBLIC KEY-----`;

/** PEM 본문(base64)을 ArrayBuffer로. importKey('spki'|'pkcs8')가 먹는 모양. */
export function pemToBuffer(pem: string): ArrayBuffer {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(body);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

/** base64url 문자열을 Uint8Array로(JWT 서명·클레임 디코딩). */
export function base64urlToBytes(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
