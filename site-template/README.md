# My Journal — cocoWriter blog template

cocoWriterの記事・写真をGitHub Pagesへ公開する、独立した静的ブログです。Webサーバーやデータベースは不要です。

## GitHub Pagesへ公開する

1. このディレクトリの**中身すべて**（`.github/` を含む）を、新しいGitHubリポジトリのルートへ登録します。アプリ側の `tools/create-blog.py` で独立したコピーを作成できます。
2. `site.config.json` の `title` と `description` を変更し、`src/content/diary/welcome.md` のサンプル記事を削除または編集します。
3. GitHubの Settings → Pages → Source を **GitHub Actions** に変更します。
4. `main` ブランチへpushするか、Actions → Publish blog to GitHub Pages → Run workflowを実行します。
5. Actionsが成功したら、Settings → Pagesに表示されたURLを開きます。

GitHub Actionsでは `actions/configure-pages` が取得した公開URLを使います。ユーザーサイト、`/リポジトリ名/` 配下のプロジェクトサイト、Pagesに設定済みの独自ドメインでリンク・写真・CSS・canonical URLが揃います。[公式のカスタムワークフロー](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)

`main` 以外を公開用ブランチにする場合は `.github/workflows/pages.yml` の `on.push.branches` とPages環境の許可ブランチを変更してください。

## ローカルで表示する

Node.js 22以降を使います。

```sh
npm ci
npm test
npm run preview
```

ローカル表示は `site.config.json` の `siteURL`（HTTPSのドメイン部分だけ）と `basePath`（`/my-journal/`、ルートなら `/`）を使います。自分の公開先へ変更してください。`SITE_URL` と `BASE_PATH` の環境変数を指定すると、この設定を上書きできます。GitHub Actionsではこれらを自動設定します。

```sh
SITE_URL=https://username.github.io BASE_PATH=/my-journal/ npm run build
```

出力先は `dist/` です。保存形式は `blog-profile.json` で設定できます。アプリの `BlogProfile.json` と同じ内容にしてください。保存先・画像公開パス・Front Matter・項目名・拡張子・除外記事名を反映します。設定変更時は既存の記事・写真も移動してください。URLのパスはリポジトリ内の保存先には加えません。写真のMarkdownは `![説明](/images/diary/...)` のまま保存し、ビルド時にサイトのパスを付けます。

## アプリから投稿する

cocoWriterの設定に、このリポジトリのowner、repository、branch、**Settings → Pagesに表示された公開URL全体**を入力します。対象リポジトリのContents読み書き権限を持つFine-grained tokenをアプリに保存します。

標準設定では記事は `src/content/diary/*.md`、写真は `public/images/diary/<UUID>/<SHA-256>.jpg` です。保存先・ヘッダーを変えても、このテンプレートが生成する記事URLは `/posts/<ファイル名>/` です。ファイル名に空白・日本語・記号がある場合もURLをエンコードします。

```markdown
---
title: "記事タイトル"
description: "記事の説明"
date: 2026-10-05
tags: ["日記"]
---

ここに本文をMarkdownで書きます。
```

曲・アルバムのSpotify埋め込みを表示できます。それ以外のHTMLは文字として表示します。本文はビルド時にMarkdownからHTMLへ変換し、サイトのJavaScriptは実行しません。未配置の添付写真や不正な記事ヘッダーがある場合は公開ビルドが失敗し、以前の公開サイトを保持します。

絶対URL方式を選んだ場合は、`site.config.json` の `siteURL` と `basePath` をアプリの公開サイトURLと一致させます。そのURLとPagesが取得した公開URLの画像を認識し、公開・ローカル表示のパスへ置き換えて写真を配置します。

## ライセンス

テンプレートのコードとスタイルは[MIT](LICENSE)。npm依存は[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md)を参照してください。自分の記事・写真のライセンスは別途決めてください。
