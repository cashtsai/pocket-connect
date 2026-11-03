# CI 發版(macOS 簽名 + 公證 + 發佈)

2026-11-03 起,推 `v*` tag 會觸發 `.github/workflows/release-macos.yml`:
macOS runner 上簽名(Developer ID)→ 公證 → staple → 煙霧測試 → 把
`Pocket-<ver>.dmg` + `.sha256` 掛上 GitHub Release。管線做法參考
t3code(MIT)的 `release-desktop.yml` / `sign-macos.ts` / `smoke-desktop-app.ts`。

本機發版路徑**完全保留**(`NOTARIZE=1 BUNDLE_BRIDGE=1 ./packaging/build_dmg.sh`),
行為一字未變 —— CI 模式只在 `MACOS_CERTIFICATE_P12_BASE64` 有值時啟動。

## 為什麼 CI 現在可以碰 release 資產了

舊 `release.yml`(已被取代刪除)寫死「CI 永不碰正式 release 資產」。根因是
v0.3/v0.4 空包事故:CI 抓不到私有 bridge repo → 建出沒 bridge 的 DMG →
跟本機正貨賽跑還搶先上架。新管線修根因,不是繞開:

1. **bridge 用 deploy key checkout** —— 抓不到 = job 直接失敗,不帶病前進。
2. **build_dmg.sh 既有守門** —— `NOTARIZE=1` 而沒 `BUNDLE_BRIDGE=1` 直接報錯。
3. **smoke_dmg.sh 行為探針** —— 用 app 自己的 `POCKET_ENV_DOCTOR=1` 乾跑出口,
   驗「app 真的偵測得到內附 bridge(`bridgeSource=bundled(…)`)」。
   空包在發佈前就死在這一步,不會活著到 releases。

## Secrets 清單(repo → Settings → Secrets and variables → Actions)

沿用 2026-07 就設好的既有名稱(別被其他文件裡的 `MACOS_CERT_P12_BASE64` /
`ASC_API_KEY_P8` 之類提案名騙了 —— repo 裡實際存在的是下面這組):

| Secret | 內容 | 2026-11-03 狀態 |
|---|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Developer ID Application 憑證 + 私鑰的 .p12,base64 | ✅ 已設(7/23) |
| `MACOS_CERTIFICATE_PASSWORD` | 匯出 .p12 時設的密碼 | ✅ 已設 |
| `DEVELOPER_ID_PROFILE_BASE64` | `pocket-desktop-developer-id.provisionprofile`,base64 | ✅ 已設 |
| `APPLE_NOTARY_KEY_P8_BASE64` | App Store Connect API key(AuthKey_*.p8),base64 | ✅ 已設 |
| `APPLE_NOTARY_KEY_ID` | 上述 key 的 Key ID | ✅ 已設 |
| `APPLE_NOTARY_ISSUER_ID` | ASC API 的 Issuer ID | ✅ 已設 |
| `BRIDGE_DEPLOY_KEY` | `cashtsai/hermes-openwebui-bridge` 的 read-only deploy key(SSH 私鑰全文) | ❌ **待設,唯一缺的** |

⚠️ 7/23 設的那批從未被完整走通過(舊 workflow 只上傳 smoke artifact)。
首次驗證(見下)把每一顆都當成「可能是壞的」。

### BRIDGE_DEPLOY_KEY 怎麼設(機主本機操作)

```sh
ssh-keygen -t ed25519 -N "" -C "pocket-connect-ci-bridge-ro" -f /tmp/bridge_deploy_key
# 公鑰 → bridge repo 的 Deploy keys(read-only,不勾 write):
gh repo deploy-key add /tmp/bridge_deploy_key.pub \
  -R cashtsai/hermes-openwebui-bridge --title "pocket-connect release CI (ro)"
# 私鑰 → pocket-connect 的 secret:
gh secret set BRIDGE_DEPLOY_KEY -R cashtsai/pocket-connect < /tmp/bridge_deploy_key
rm /tmp/bridge_deploy_key /tmp/bridge_deploy_key.pub
```

### 憑證 .p12 怎麼從本機匯出(機主本機操作;輪替憑證時要重做)

```sh
# 1. 找到憑證(名稱:Developer ID Application: chia hsiang tsai (4F8B93R3SH))
security find-identity -v -p codesigning | grep "Developer ID Application"
# 2. Keychain Access.app → 登入 → 我的憑證 → 右鍵該憑證(連同私鑰)→ 輸出… → .p12,設一組密碼
#    (命令列 `security export -t identities -f pkcs12` 也行,但 GUI 匯出最不容易漏掉私鑰)
#    ⚠️ 不要用 openssl 3 重新打包 p12:預設的 AES/MAC 格式 macOS `security import`
#    會報「MAC verification failed」(實測)。真要用 openssl 就加 `-legacy`。
# 3. 餵進 secrets:
base64 -i ~/Desktop/pocket-developer-id.p12 | gh secret set MACOS_CERTIFICATE_P12_BASE64 -R cashtsai/pocket-connect
gh secret set MACOS_CERTIFICATE_PASSWORD -R cashtsai/pocket-connect   # 互動輸入 .p12 密碼
rm ~/Desktop/pocket-developer-id.p12
```

provisioning profile 與 ASC key 同理:

```sh
base64 -i "$HOME/Library/MobileDevice/Provisioning Profiles/pocket-desktop-developer-id.provisionprofile" \
  | gh secret set DEVELOPER_ID_PROFILE_BASE64 -R cashtsai/pocket-connect
base64 -i ~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \
  | gh secret set APPLE_NOTARY_KEY_P8_BASE64 -R cashtsai/pocket-connect
```

Key ID / Issuer ID 在 `~/.pocket-release.env`(`ASC_KEY_ID` / `ASC_ISSUER_ID`)。

## 首次驗證流程(不用燒 tag)

workflow 有 `workflow_dispatch` 乾跑道:整條建置+簽名+公證+煙霧全跑,
但**不**發佈 release(產物只掛 workflow artifact)。

1. 設好 `BRIDGE_DEPLOY_KEY`(其餘六顆已在)。
2. `gh workflow run release-macos.yml -R cashtsai/pocket-connect --ref main`
3. `gh run watch -R cashtsai/pocket-connect` —— 四個會死的點依序是:
   bridge checkout(deploy key 壞)、CI 簽章模式(p12/密碼壞)、
   notarytool(ASC key 壞)、smoke(包本身壞)。哪步死修哪顆 secret。
4. 綠了之後,下載 workflow artifact,本機再走一次
   `mac-app/packaging/smoke_dmg.sh <下載的 dmg>` 當雙保險。
5. 下一次正式發版照常 `./packaging/cut_release.sh patch` —— tag 推上去 CI
   全自動,發佈後跑 `mac-app/packaging/verify_release.sh v<ver>` 驗
   **使用者真的會下載到的那顆**(這關永遠不可省:v0.5.1/v0.8.0 都是在這關
   以後才抓到的)。

CI 壞掉時本機後備照舊(cut_release.sh 的輸出有完整指令)——
唯一紅線:**不要跟 CI 同時上傳**,先取消 run 再動手。

## 煙霧測試在驗什麼

`mac-app/packaging/smoke_dmg.sh <dmg>`(本機也能跑):

- DMG:spctl(簽章)、stapler validate(票據)、sha256 檔相符
- app(掛載後):codesign --deep --strict、spctl execute、stapler validate
- 主程式 + cloudflared + frpc 都是 universal(少一個架構 = 安靜地對一半使用者壞掉)
- bridge payload 存在 + `BRIDGE_VERSION.txt` 可讀(`EXPECT_BRIDGE=0` 可關)
- **啟動行為探針**:複製出 DMG(模擬拖進 Applications)後以
  `POCKET_ENV_DOCTOR=1` 乾跑,install root / LaunchAgents / port 全指向
  臨時位置(= 模擬全新 Mac,也絕不碰本機真的在跑的 bridge),驗 app 印得出
  合法 JSON 且 `probe.bridgeSource` 是 `bundled(…)`。

分工:`smoke_dmg.sh` 驗**發佈前**那顆(CI 內),`verify_release.sh` 驗
**發佈後**使用者下載到的那顆。兩關都要過。

## 下一步:nightly → stable 晉升制(本輪未做,先記設計)

t3code 的做法值得抄的核心:**stable 永遠發佈「已經當過 nightly 的那個 commit」,
不是 main HEAD**。nightly 就是 release candidate;驗過 nightly 才晉升,
驗證期間 main 繼續合併也不會漏進 stable 包。

對應到 Pocket 的落地草稿:

1. 加 `schedule` + `channel=nightly` 的 dispatch:建置+簽名+公證照跑,
   發到 prerelease(tag 形如 `v1.0.2-nightly.<date>`),永不標 latest。
2. `channel=stable` 的 dispatch:輸入一個 nightly tag,checkout **那個 commit**
   重建(或直接晉升其資產),打正式 tag,`--latest` 標上。
3. 版本號規則沿用 `cut_release.sh` 的 Info.plist 單一事實來源;nightly 的
   prerelease 後綴只進 tag/release 名,不進 Info.plist。
4. 官網下載連結(pocketone.app)指 stable latest;nightly 僅手動取用。

先跑穩 tag 觸發這條,晉升制等 CI 發過兩三版沒出事再上。
