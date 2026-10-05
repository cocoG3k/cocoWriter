# 同じソースから、自分用のアプリを作る

cocoWriterでは、ブログの記事形式に加えて、アプリの識別子・表示名・保存先・公開先の初期値を設定できます。設定ごとにXcodeプロジェクトを生成し、Swiftのソース・アイコン・テストは `ios/` の共通ファイルを直接参照します。別のアプリとしてソースを複製する必要はありません。

## 新しい設定を作る

```sh
mkdir -p .local/my-blog
cp config/app/default.json .local/my-blog/profile.json
# profile.json を自分のブログ・アプリに合わせて編集
python3 tools/configure-variant.py .local/my-blog/profile.json --output .local/my-blog/ios
open .local/my-blog/ios/cocoWriter.xcodeproj
```

`blogProfile` は設定ファイルからの相対パスです。この場所にコピーした場合、標準設定なら `../../config/default.json`、Jekyllなら `../../config/jekyll.json` に変更します。記事形式やプレビューの設定は[記事形式ガイド](content-format.md)を参照してください。

| 項目 | 設定するもの |
| --- | --- |
| `displayName` | iPhoneと共有メニューに表示するアプリ名 |
| `bundleIdentifier` | アプリ本体の識別子 |
| `extensionBundleIdentifier` | 共有拡張の識別子。本体の識別子に続く値 |
| `appGroupIdentifier` | 本体と共有拡張の共有領域 |
| `storageDirectory` | Application Support内の保存フォルダ名 |
| `keychainService` | GitHubトークンのKeychainサービス名 |
| `defaultSite` | owner・repository・branch・website・title・taglineの初期値 |
| `blogProfile` | 記事形式・画像パス・プレビューの設定ファイル |
| `developmentTeam` | 任意。自分の署名Team。AltStore用のIPA作成では署名に使いません |
| `version` / `build` | 任意。その設定用のバージョン・ビルド番号 |
| `legacyDestinationID` | 任意。旧アプリの記事が接続していた `owner/repository@branch`（ownerとrepositoryは小文字） |

`.local/` はGitと配布ZIPの対象外です。トークンは設定ファイルへ記載せず、アプリのKeychain設定から保存します。`defaultSite` は初回の公開先を設定するもので、端末に保存済みの接続設定は上書きしません。

## 既存アプリのデータを引き継ぐ

プロジェクト名やSwiftのモジュール名を変えても、既存アプリを更新するには元のBundle Identifierを維持します。[Appleの識別子の説明](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier)

さらに、元の保存フォルダ・Keychainサービス・共有拡張とApp Groupを設定に転記します。アプリは指定したフォルダを直接読み、下書き・メモ・メモのタグ・曲のストック・写真を別の場所へ移動したり削除したりしません。旧形式の記事では省略されていた設定情報を読み取れます。

旧アプリが固定の公開先を使っていた場合は `defaultSite` と `legacyDestinationID` にその公開先を設定してください。投稿済み・確認待ち・写真の復元履歴を持つ記事を元の公開先に結び付け、別のリポジトリへ送ることを防ぎます。記事の読み込みだけでは下書きJSONを書き換えません。

AltStore版は同じApple Accountで既存アプリへ上書きします。AltStoreが付けた識別子の接尾辞をソースのBundle Identifierへ追加しません。既存アプリを先に削除したり、XcodeのRunで置き換えたりしないでください。元の公開先・記事形式を維持し、更新後に下書き・メモ・写真・曲ストックを確認します。

## 設定した版のIPAを作る

```sh
python3 tools/configure-variant.py .local/my-blog/profile.json --output .local/my-blog/ios
COCOWRITER_IOS_DIR="$PWD/.local/my-blog/ios" \
COCOWRITER_BUILD_DIR="$PWD/.build-cache/my-blog-altstore" \
COCOWRITER_OUTPUT_DIR="$PWD/.local/my-blog/altstore" \
./build-altstore-ipa.command
```

共有拡張のApp Groupを保持するad-hoc署名でIPAとAirDrop用ZIPを作ります。実機用の署名はAltStoreが行います。`COCOWRITER_DISTRIBUTION_NAME` を指定すると配布ファイル名も変更できます。

プロジェクト設定・リソースを変更したら生成をやり直してください。Swiftの編集はすべての設定へ即座に反映されます。
