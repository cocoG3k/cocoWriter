# cocoWriter

**自分のGitHub Pagesへ記事と写真を投稿する、iPhone用のオープンソース執筆アプリ。**

An open-source iPhone Markdown writer for your own GitHub Pages blog. Includes a standalone blog template. [English guide](docs/README.en.md)

[![Validate cocoWriter](https://github.com/cocoG3k/cocoWriter/actions/workflows/ci.yml/badge.svg)](https://github.com/cocoG3k/cocoWriter/actions/workflows/ci.yml)

CocoG Writerを元にした独立プロジェクトです。元のプロジェクト・実機アプリ・保存データを変更せず、別のアプリ識別子と保存領域を使います。特定のドメインやGitHubアカウントには接続しません。

## できること

- 日記・記事の下書き、Markdown編集、プレビュー、書き出し
- 公開先の記事ページのHTML・CSSをビルド時に指定するテーマ付きプレビュー（sfuji.orgの設定例を同梱）
- 写真を位置情報・撮影情報を除いたJPEGへ変換し、記事と一緒に1コミットで投稿
- Spotifyの曲・アルバム紹介、曲のストック、YouTube Music共有拡張
- 自分用メモ・日記を端末内に保存
- 投稿済み記事の読み込み、編集、公開解除。競合時は端末の編集を保護
- GitHubユーザー名／組織名・リポジトリ・ブランチ・公開URL・プレビューのサイト名を設定
- ビルド時に記事・画像の保存先、画像公開パス、YAML／TOML／JSONのFront Matterと項目名を設定

ユーザーサイト `https://username.github.io/`、プロジェクトサイト `https://username.github.io/my-journal/`、独自ドメインに対応します。

アプリ本体はiOSネイティブです。GitHub Pagesに公開するのはブログです。任意のGitHub Pagesサイトへ無条件で投稿できるわけではなく、[記事形式](docs/content-format.md)に対応するサイトが必要です。Jekyllの `_posts/`、Hugoの `content/posts/` などは、[ビルド設定](docs/content-format.md)で書き出し形式を合わせられます。

## 最短の導入手順

まずソースを取得します。

```sh
git clone https://github.com/cocoG3k/cocoWriter.git
cd cocoWriter
```

Macでソースからビルドして利用します。App Storeでの配信はありません。

### 1. ブログを用意する

```sh
python3 tools/create-blog.py ../my-journal
cd ../my-journal
```

作成されたディレクトリの[README](site-template/README.md)に従い、その内容を新しいGitHubリポジトリの**ルート**へ登録します。`site-template/` 自体をリポジトリ直下のサブフォルダに置く構成ではありません。ブログにはサンプル記事が1件入っているため、公開前に削除・編集してください。

GitHubの Settings → Pages → Build and deployment → Source を **GitHub Actions** にし、Actionsの「Publish blog to GitHub Pages」を実行します。ワークフローが公開URLを取得し、リポジトリ名を含むパスを自動で反映します。[GitHub公式手順](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)

既存ブログを使う場合は、[ビルド設定](docs/content-format.md)で、そのサイトに合わせた保存先とFront Matterを指定します。

### 2. iPhoneアプリをビルドする

必要なものはMac、Swift 6.2以降を含むXcode、iOS 17以降です。Swift Markdown 0.8.0を初回ビルド時に取得します。

```sh
cd ../cocoWriter
# 既存サイトなら config/jekyll.json や config/hugo-toml.json を選択
python3 tools/configure-blog.py config/default.json
python3 tools/configure-signing.py --bundle-id com.yourname.cocoWriter
open ios/cocoWriter.xcodeproj
```

`com.yourname.cocoWriter` は自分固有の識別子に変更してください。この補助ツールは本体・共有拡張・App Groupの識別子を一緒に変更します。公開用の初期値は `org.example.cocoWriter` で、署名チームは空です。

Xcodeで `cocoWriter` と `cocoWriterShare` の Signing & Capabilities に自分のTeamを設定し、同じApp Groupを登録します。実機で共有拡張を使うには、そのApp Groupへアクセスできる署名が必要です。[AppleのApp Group説明](https://developer.apple.com/documentation/xcode/configuring-app-groups)

Scheme `cocoWriter` と実行先のiPhoneを選び、Runします。元のCocoG Writerはそのまま残ります。自分でアプリ識別子を元アプリと同じにしないでください。

AltStore用のIPAを作る場合は `./build-altstore-ipa.command` を実行します。生成先は `altstore/` です。実機用の署名はAltStoreで行います。共有拡張を取り込み対象に残してください。

### 3. 公開先を設定する

アプリの「設定」→「GitHub公開の接続設定」で次を入力し、「公開先の設定を保存」を押します。

| 設定 | プロジェクトサイトの例 |
| --- | --- |
| GitHubユーザー名・組織名 | `username` |
| リポジトリ名 | `my-journal` |
| ブランチ | `main` |
| 公開サイトURL | `https://username.github.io/my-journal/` |
| サイト名・説明 | 自分のブログ名・説明 |

ブログの `site.config.json` にも同じサイト名と説明を設定します。アプリの設定は端末内のプレビューを変更するもので、サイト設定ファイルを自動更新しません。

GitHubで対象リポジトリだけを選んだFine-grained personal access tokenを作り、**Contents: Read and write** を許可して、アプリのSecureFieldからKeychainに保存します。アプリはワークフロー自体を書き換えないため、投稿用トークンにWorkflowsの書き込み権限は不要です。[GitHubの権限一覧](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)

ブランチを変更する場合は、ブログ側の `.github/workflows/pages.yml` の `on.push.branches` とPagesの環境の許可ブランチも揃えます。保護ブランチに直接書き込めない設定では投稿できません。この版はPR経由の投稿に対応していません。

### 4. 記事を公開する

下書きを作成し、プレビューと送信内容を確認して「この内容をGitHubに保存・公開」を押します。GitHubへの保存後、サイトのActionsが成功したことと公開ページを確認します。GitHubのコミット成功とPagesへの反映は別の段階です。

## 保存と公開先の変更

記事・自分用メモ・曲ストックは端末内に保存されます。自分用メモをGitHubへ送る機能はありません。クラウド同期はなく、アプリを削除すると端末内データも失われるため、必要な記事は書き出して保管してください。

公開先を変えると保存済みトークンを削除します。投稿済み・送信結果の確認待ち・GitHub由来の記事や画像の復元履歴がある間と、GitHubへの通信中は投稿先の変更を停止します。サイト名・公開URLは変更できます。別の投稿先へ移る場合は記事を書き出し、確認待ちを解決し、接続済みの記事を**端末のゴミ箱から完全削除**してから変更してください。端末からの整理と「公開解除」は別の操作です。

既存のCocoG Writerの保存データ・認証情報は自動移行しません。

## 開発・確認

```sh
python3 tools/check-project.py
python3 tools/test_build_profiles.py
python3 tools/test-ios.py
cd site-template
npm ci
npm test
npm run build
npm run preview
```

ブログにはNode.js 22以降が必要です。プレビューURLはコマンドの出力に表示されます。ルートのGitHub ActionsはiOSテストとブログのビルドを行い、ブログを公開するワークフローは `site-template/.github/workflows/` にあります。

現在の確認範囲は[検証記録](docs/VALIDATION.md)を参照してください。

## 構成・ライセンス

```text
config/                 標準・Jekyll・Hugo・sfuji.org用のビルド設定例
ios/                    アプリ・共有拡張・Xcodeプロジェクト・XCTest
preview-templates/      サイトの見た目に合わせるHTML/CSSとライセンス
site-template/          独立したGitHub Pagesブログの雛形
tools/                  ブログ作成・識別子設定・ビルド確認
docs/                   記事形式・英語ガイド・検証記録
.github/workflows/      公開プロジェクトのCI
```

プロジェクトのコードと同梱する独自の素材は[MIT License](LICENSE)です。Swift Markdown、cmark、ブログのnpmパッケージはそれぞれのライセンスが適用されます。[第三者ライセンス](THIRD_PARTY_NOTICES.md)と同梱する原文の通知を保持してください。生成したブログ記事や利用者の写真の権利を、このライセンスへ変更するものではありません。

[GitHubでの公開・ソースZIPの作成手順](docs/publishing.md)も用意しています。変更の提案は[CONTRIBUTING](CONTRIBUTING.md)を参照してください。
