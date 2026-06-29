# openssl + 사설 rootCA 기반 TLS (mkcert 대체)

mkcert 대신 **openssl로 50년짜리 사설 rootCA**를 만들고, 그 CA로 와일드카드 인증서를 발급해
Web IDE extension host domain의 TLS를 구성하는 방법.

## 시나리오

| 단계 | 내용 |
|------|------|
| rootCA | 50년(`18250d`) 사설 root. `mkcert -install` 대신 이걸 신뢰시킨다. |
| `*.test.localhost.me` | 같은 CA로 발급된 **기존** 와일드카드 (이미 구성돼 있다는 가정용 예시) |
| `*.gitlab.localhost.me` | 같은 CA로 발급한 **신규** 와일드카드 → Web IDE extension host domain |

> 핵심: rootCA 하나만 신뢰시키면, 그 CA로 서명한 모든 와일드카드(`test`, `gitlab`, 이후 추가분)가
> 자동으로 신뢰된다. 도메인 추가할 때 CA 재신뢰가 필요 없다.

메인 GitLab(`gitlab.localtest.me`)은 그대로 두고, extension host 자산 origin만 이 CA 기반
`*.gitlab.localhost.me`로 바꾼 구성이다.

## 1) CA + 인증서 생성

```bash
cd tls-openssl
./gen-certs.sh
# 산출물:
#   rootCA.crt / rootCA.key                       (50년 root)
#   test_localhost_me.{crt,key,fullchain.crt}     (*.test.localhost.me)
#   gitlab_localhost_me.{crt,key,fullchain.crt}   (*.gitlab.localhost.me)
```

`*.fullchain.crt` = leaf + rootCA. nginx-ingress에는 풀체인을 넣는다.

변수: `CA_DAYS`(기본 18250=50년), `LEAF_DAYS`(기본 3650=10년). 브라우저가 leaf 수명을
거부하면 `LEAF_DAYS=825 ./gen-certs.sh`로 재발급.

## 2) k8s TLS secret 생성

```bash
kubectl -n gitlab create secret tls webide-exthost-tls \
  --cert=gitlab_localhost_me.fullchain.crt \
  --key=gitlab_localhost_me.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

## 3) extension host ingress를 새 도메인/secret으로

[../webide-extension-host-ingress.yaml](../webide-extension-host-ingress.yaml) 가 이미
`*.gitlab.localhost.me` + `webide-exthost-tls` 를 가리키도록 갱신돼 있다.

```bash
kubectl apply -f ../webide-extension-host-ingress.yaml
```

## 4) GitLab 관리자 설정

```bash
POD=$(kubectl -n gitlab get pod -l app=toolbox -o jsonpath='{.items[0].metadata.name}')
kubectl -n gitlab exec "$POD" -- gitlab-rails runner '
  s = ApplicationSetting.current
  s.vscode_extension_marketplace_extension_host_domain = "gitlab.localhost.me"
  v = s.vscode_extension_marketplace; v["single_origin_fallback_enabled"] = false
  s.vscode_extension_marketplace = v; s.save!'
```

## 5) 로컬 와일드카드 DNS (브라우저 테스트용)

`localhost.me` 는 `localtest.me` 와 달리 공개 와일드카드가 아니라서 직접 해석시켜야 한다.
extension host는 `<hash>.gitlab.localhost.me` 동적 서브도메인을 쓰므로 dnsmasq 와일드카드가 필요.

```bash
cd ../dns
sudo ./setup-dns.sh      # dnsmasq address 라인 + /etc/resolver/localhost.me + dnsmasq 재시작
```

curl 검증만 할 거면 이 단계는 생략하고 아래 `--resolve` 를 쓰면 된다.

## 6) rootCA 신뢰 (브라우저 인증서 경고 제거)

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain tls-openssl/rootCA.crt
```

## 7) 검증

DNS 없이 즉시(라우팅 + CA 체인):

```bash
ASSET=$(curl -ksS https://gitlab.localtest.me/users/sign_in \
  | grep -oE '/assets/[A-Za-z0-9._/-]+\.css' | head -1)
curl -sS --resolve "abc123.gitlab.localhost.me:443:127.0.0.1" \
  --cacert tls-openssl/rootCA.crt \
  -o /dev/null -w "%{http_code} %{ssl_verify_result} %{size_download}\n" \
  "https://abc123.gitlab.localhost.me$ASSET"
# 200 0 <size>  => HTTP 200, TLS 검증(0=성공), 자산 정상
```

dnsmasq까지 했으면 `--resolve` 없이 그대로 접속/브라우저 테스트 가능.

## 정리

```bash
kubectl -n gitlab delete secret webide-exthost-tls
sudo rm -f /etc/resolver/localhost.me
# dnsmasq.conf 의 address=/*.localhost.me/ 라인 수동 제거 후: sudo brew services restart dnsmasq
sudo security delete-certificate -c "Local Dev Root CA (50yr)" /Library/Keychains/System.keychain
```
