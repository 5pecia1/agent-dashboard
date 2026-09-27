// Bytes of app/flutter_app/web/favicon.png. The server package ships only dist/,
// so the icon is inlined instead of read from the Flutter web directory.
const FAVICON_PNG_BASE64 = `iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAD9UlEQVR4nO1XW28bRRT+zuzs+paLnRQo
bUJFlYS4kaK2XAsSL1WFuF+kggQSb4gfgAR/gj8AvMBLX/qCBIpQWjWoRQ0gBH1ApGrTpilENDS213Ec
r/cyg2bWTnyLHRukgNQjjR2Nd8/55sz3nXNC8US/xB4a28vg9wD8JzLAGzeISC8ppV5VY6w9VvWolOKf
ASAieK4L3/dhWRYMzreAlDY3IdEsGALpfQXQsiK9AyAiuK6LAwdHcf/+B3Hr5nXkbRsGY+CmiYn0FCwz
Ep6SqO7oxBgK63ncunE9zFTt77sBQMRQLjtIT03j9TffgWlayGUzOPPFp7CzGbzx1rsYnzyCwPfVkZtN
AoZh4OLcLOZmZ2BFFFDZTQakXsceexKMGbDtLIb33YexiTSWl25gbGIS63kbTHGjVXwpwTnH9LHH8ePl
S3CckvYT+t1VBghSSH3qSDQK3/d0WvN2DsViQWcnnkggCAJ95/WOCUIKxKIxZNZu6mdDwnaRASklTMvC
pW/PaQD7D4xg/rs5LF5b0IT8+suzeOqZZzWoVqYOUNos4sLsDIQItK9WV6D3GrapthcoNnuOCwYDggWa
1ZqcXhnwSROy1dVq9Xiu/lvxJ5RjI1kkmGmAcaazXZcBbeoanADxwQSiD8SxsbwO6QuAMxiCo+9QP4xo
KMtWprKjQgoh60VS+SAGFFc24G244DV+ePgywXd8pNLDOPHxSfSNDmB1fgXff3QB5ZyDox+ewPjbU5BB
JfhOKtvx2pVUCcU7Rcx/cB65q5kQhJCVUkyA8AIcef84Uul98IseHnphDCOnHkb/4STS7x0NEavA7SRO
Oy2C8CVSk8M6hopV9cPauOtwqn/HWDWIIshvn/yM3MIaeNzE7ZlF/HFuCYUlGwufXdFEq5SLZoAdlwTj
pFOvYqhYVT+0pQKVJseHNRDZJmEgQJxBuAJ9o80kVHoPm1A98RrxtSMh9SpDFdD1XDBiugqGDtsRRIJZ
BpjRQoZEpKtcNBbDi6+e1oVo4dcruHxxDp7nYWr6eFMhUqe3c1mc/+Yr5HNZcG51JIzurDXB6wCoNnzq
+Vfw6BNPo7hRwMnnXsZfq3ew8vsyXnrttO6I26UYuvweHDmkHZ498zkMo35+2K3xKjKl09TQMMqOg1Jp
E7FYHIODKdjZLCKRKAqF9bpmpN8BIZkaqrmC7o2FX6Fgf/npB13Lk8khZNbu6l5wd/VPLF67ioHBJGLx
hG5KaiUSfTBNU7+jyvBOfaKTUZWEnQaSw+OPbA8kFQ5kM2u4vbykM9CrUa0K2o1kbrm8NZJVxzA1hCil
9Jr+JgDdDqWNz/RifLdOheh+4v1f/F/A7gHAHtvfRS0IKje8N/8AAAAASUVORK5CYII=`;

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value.replace(/\s/g, ""));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

export const FAVICON_PNG: Uint8Array = decodeBase64(FAVICON_PNG_BASE64);
