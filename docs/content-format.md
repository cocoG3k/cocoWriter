# ブログの記事設定

記事・画像の保存先とFront Matterは、アプリの設定画面でカテゴリごとに変更できます。ビルド時のJSONは初期値を指定するために使います。利用するサイトの生成処理が、アプリの保存するMarkdown・JPEGを受け入れる構成にしてください。

設定ファイルは [`ios/cocoWriter/BlogProfile.json`](../ios/cocoWriter/BlogProfile.json) です。XcodeのResourcesに登録してあり、Run／Archive／IPA作成時にアプリへ同梱します。変更後は再ビルドが必要です。トークン・GitHubアカウント・リポジトリ・ブランチ・公開サイトURLは、アプリの接続設定で指定します。

## アプリ内でカテゴリを複数使う

「設定 → 記事のカテゴリ・タグ」で、日記・旅などの名前と記事フォルダを登録し、使うカテゴリを複数チェックして保存できます。「GitHubから保存先を探す」はMarkdownがあるフォルダを候補として追加します。READMEなどのフォルダも候補になるため、記事が入るフォルダだけを選んでください。新しい空のフォルダは「カテゴリを追加」で登録できます。

新規作成は「記事を書く」から共通の編集画面を開き、カテゴリを選びます。本文エディタ上部の曲紹介ボタンから、曲紹介を書いたりストックを選んだりできます。画像ボタンからは写真・画像ファイルを追加できます。本文を広く開いた画面にも同じボタンがあります。曲紹介はどのカテゴリでも追加でき、本文のあとに掲載されます。既存の公開記事への曲追加にも対応します。

カテゴリは保存先フォルダ、タグは記事につけるラベルです。同じ設定画面でタグ候補を追加・削除して保存でき、記事作成画面から複数選択できます。自由入力したタグも併用できます。タグの選択では保存先が変わらず、カテゴリを切り替えても記事のタグは残ります。候補を削除しても既存の記事のタグは変わりません。

カテゴリ名を開くと、記事フォルダ・画像フォルダ・画像公開パス・画像リンク形式を変更できます。ヘッダー形式（YAML・TOML・JSON）、タイトル・説明・日付・タグの項目名、説明文の必須設定、日付形式・タイムゾーン、ファイル名、読み込む拡張子、除外するファイル名、固定項目も設定できます。ビルドし直す必要はありません。新しいカテゴリの初期値は使用中のカテゴリを引き継ぎ、最初のカテゴリだけビルド設定を使います。例えばsfuji用の日記設定なら、旅カテゴリに `src/content/journey`、`public/images/blog/journey`、`/images/blog/journey` を指定します。プレビューテーマはアプリ共通で、カテゴリ別のテーマ切り替えはありません。

「完了」でカテゴリ一覧へ戻り、「カテゴリ設定を保存」で反映します。設定変更は新しい記事に使い、保存済みの記事は作成時の保存先・記事形式・画像リンクを保ちます。変更後にGitHubから一覧を更新する場合も、端末にある記事はその記事の設定で読み込みます。保存先の変更は、既存ファイルを移動する操作ではありません。

公開前の下書きはカテゴリを変更でき、添付写真の参照も移ります。読み込んだ記事の未知のメタデータを守るため、その記事を異なるヘッダー設定へ変換する操作には対応しません。公開済み・送信結果の確認待ちの記事は元の保存先を保持します。カテゴリのチェックを外しても既存記事は残り、そのカテゴリはGitHubからの一覧更新の対象外になります。設定したフォルダに初めて読み込む既存記事がある場合は、その記事が使う項目名を設定してください。

## 設定項目

| 項目 | 用途・標準値 |
| --- | --- |
| `schemaVersion` | 設定形式のバージョン。`1` |
| `articleDirectory` | リポジトリ内の記事保存先。`src/content/diary`。空文字でリポジトリ直下 |
| `imageDirectory` | リポジトリ内の画像保存先。`public/images/diary` |
| `imagePublicPath` | サイトの基点からの画像公開パス。`/images/diary`。末尾の `/` は不要。サイト直下なら `/` |
| `imageReferenceStyle` | `site-relative` または `absolute`。後述 |
| `filenameTemplate` | 新規記事のファイル名。`ios-{id}.md`。`{id}`を1つ含める。`{date}`、`{year}`、`{month}`、`{day}`と下位フォルダも利用可能 |
| `articleExtensions` | 読み込む記事の拡張子。`md`、`markdown` |
| `excludedArticleNames` | 各階層で読み込みから除くファイル名。標準ではHugoの一覧用 `_index.md` |
| `frontMatter.format` | 新規記事のヘッダー。`yaml`（`---`）、`toml`（`+++`）、`json`（先頭のJSONオブジェクト） |
| `frontMatter.fields` | タイトル・説明・日付・タグの項目名。`title`、`description`、`date`、`tags`。説明とタグは `null` で出力しない |
| `frontMatter.requireDescription` | 説明文を必須にするか。`true` |
| `frontMatter.dateStyle` | `date` = `2026-10-05`、`iso8601` = `2026-10-05T12:34:56+09:00`、`jekyll` = `2026-10-05 12:34:56 +0900` |
| `frontMatter.timeZone` | 日付とファイル名に使うIANAタイムゾーン。`Asia/Tokyo`、`UTC`等 |
| `frontMatter.extra` | 新規記事に加える固定項目。例: `layout: post`、`draft: false`、`published: true`、`author`、`categories`。文字列・真偽値・数値・文字列配列を使用可能 |

保存先の深さは限定しません。設定するフォルダ・ファイル名には英数字・日本語などの文字、`_`、`-`、`.`と区切りの `/` を使えます。`..`、絶対ファイルパス、空のパス要素、空白、URLのクエリ・フラグメントは受け付けません。既存記事のファイル名の空白・記号は保持します。リポジトリ直下を記事保存先にする場合は、ヘッダーのないREADME等を `excludedArticleNames` に追加してください。

画像には指定フォルダの下に `<記事UUID>/<SHA-256>.jpg` を加えます。この部分は固定です。記事のタイトル変更でファイル名は変わりません。日付を含むファイル名は最初の送信時に確定し、それ以降の日付変更でも保存場所を維持します。

## 設定例を選ぶ

```sh
# 同梱テンプレート用の標準設定
python3 tools/configure-blog.py config/default.json

# 既存Jekyllサイト: _posts と日付付きファイル名
python3 tools/configure-blog.py config/jekyll.json

# 既存Hugoサイト: content/posts と static/images/posts
python3 tools/configure-blog.py config/hugo-toml.json
```

Hugo用には `hugo-yaml.json` と `hugo-json.json` もあります。[JekyllのFront Matter](https://jekyllrb.com/docs/front-matter/)はYAMLを、[HugoのFront Matter](https://gohugo.io/content-management/front-matter/)はYAML・TOML・JSONを使用できます。設定例は記事・画像の形式を合わせるもので、既存サイトのテーマや公開ワークフローを変更するものではありません。

自分の構成に合わせる場合はJSONをコピーして編集します。説明が `summary` という項目なら `frontMatter.fields.description` を `summary` に、タグを `categories` へ入れるなら `frontMatter.fields.tags` を `categories` に変えます。固定項目と編集項目の名前は重複できません。

```sh
python3 tools/configure-blog.py my-profile.json --check
python3 tools/configure-blog.py my-profile.json
```

確認だけなら `--check`、適用するときは省略します。適用後にアプリをビルドしてください。直接 `BlogProfile.json` を編集する場合も `--check` で検査できます。無効な設定・設定ファイルの同梱漏れがある場合は、GitHubへの通信を停止します。

同梱の独立ブログテンプレートにも、同じ設定を反映できます。

```sh
python3 tools/create-blog.py ../my-journal
python3 tools/configure-blog.py my-profile.json --blog ../my-journal
```

ブログ側は `blog-profile.json` を読みます。既存の記事・画像は自動で移動・変換しません。標準の場所に残るサンプル記事も、新しい保存先へ移すか削除してください。`--blog` は同梱テンプレート専用です。既存Jekyll・Hugoサイトには、そのサイトの公開方法を使用します。

## 画像URLとGitHub Pagesのサブパス

`imageDirectory` は保存先、`imagePublicPath` は公開後の場所です。例えばHugoでは `static/images/posts` → `/images/posts` になります。

- `site-relative`: Markdownへ `![写真](/images/posts/...)` を書きます。同梱テンプレートは公開URLの `/my-journal/` を加えて表示します。既存サイトで使う場合は、サイト側にも同じ補完処理が必要です。
- `absolute`: アプリの公開サイトURLから `![写真](https://username.github.io/my-journal/images/posts/...)` を書きます。Jekyll・Hugoの設定例はこの方式を採用し、通常のMarkdown画像として処理できます。写真追加前に公開サイトURLを設定してください。

`imagePublicPath` には `/my-journal/` を含めません。アプリが公開サイトURLから一度だけ加えます。絶対URL方式でドメイン・サブパスを変えた場合は、既存記事の画像URLも変更する必要があります。同梱テンプレートでは `site.config.json` の `siteURL` と `basePath` を公開先に合わせてください。ActionsではPagesから取得したURLも使用します。

## 既存記事と設定変更

既存記事は指定した保存先を再帰的に読み込みます。YAML・TOML・JSONはヘッダーから判別し、新規記事の出力形式と異なっていても元の形式で編集します。項目名は選んだ設定を使用します。タイトル・日付は必須です。日付は上記3形式とミリ秒3桁のISO形式を読み込めます。

編集する項目は**トップレベル**の文字列・日付・文字列配列です。YAMLの単一／二重引用符・通常の文字列・ブロック文字列、タグの1行配列／リストに対応します。TOMLの編集対象は1行の文字列・日時・配列です。TOMLの複数行文字列／配列・引用符付きキー、YAMLアンカー・別名、タグの空白区切り文字列、入れ子の項目を編集対象へ割り当てることには対応しません。読み取れない記事は更新せず、エラーを表示します。

編集対象以外の項目は保持します。YAML・TOMLは変更した項目だけを更新し、JSONはヘッダー編集時に整形し直して未知のオブジェクト・配列も保持します。本文だけを変更するときは、どの形式でもヘッダーを保持します。固定項目は新規記事へ適用し、既存記事へ一括追加しません。

下書きには作成時の設定を保存します。異なる設定のアプリへ更新しても保存先は変えず、GitHubへの送信・削除を拒否します。一覧更新でも以前の設定の記事の接続情報は消しません。元の設定で再ビルドするか、書き出して移行してください。0.1.0の下書きは標準設定として読み込みます。

写真は長辺1,600px以下・800KB以下のJPEGに変換し、GPS、EXIF、IPTC、XMP等を除去します。記事と添付写真は同じコミットで保存し、強制更新は行いません。記事の公開解除で画像ファイル・Git履歴は自動削除しません。

## サイト側で合わせる項目

公開ブランチとActionsの対象ブランチ、生成ツールとテーマ、記事URL／permalink、画像ディレクトリの公開処理、カテゴリ・公開フラグの意味、未来の日付の記事を公開するか、埋め込みHTMLの許可設定も確認してください。固定の公開フラグ等は `extra` で書けます。全記事で共通のpermalinkを指定するとURLが衝突するため、記事ごとのURLはサイト側の設定を推奨します。

任意のFront Matter項目を記事ごとに編集する機能、PR経由の投稿、GitHub Enterprise、CDN用の別画像ドメイン、任意のテンプレート言語の実行はこの版に含みません。保存成功とサイトの公開成功は別の段階なので、Actionsと実際の公開ページで確認してください。

## 公開先のテーマでプレビューする

設定ファイルに、プレビュー用HTMLの場所を追加できます。パスは設定ファイルのあるディレクトリからの相対パスです。

```json
"preview": {
  "templateFile": "../preview-templates/my-site.html"
}
```

`python3 tools/configure-blog.py my-profile.json` を実行すると、HTMLをアプリのリソースにコピーします。`--preview-template path/to/theme.html` でも指定でき、この引数を優先します。再ビルド後に反映されます。指定を外して設定ツールを実行すると共通のプレビューに戻ります。テーマだけの変更では、保存済みの記事の保存先・公開設定は変わりません。

テンプレートは `<head>` と `<body>` を持つHTMLで、本文用の `{{content}}` を1か所含めます。`preview-templates/minimal.html` を例に、公開先の記事ページのHTML・CSSを使用してください。CSSを `<style>` に含めるとオフラインでも同じ見た目を使えます。HTTPSの外部CSS・フォントも利用できますが、その場合は通信が必要です。使用するテーマのライセンスを保管してください。

| 置換項目 | 内容 |
| --- | --- |
| `{{content}}` | Markdownから生成した本文・写真・確認済みの音楽埋め込み |
| `{{title}}` / `{{description}}` | 記事のタイトル・説明文 |
| `{{date}}` / `{{dateJapanese}}` | `2026-10-05` / `2026/10/5` |
| `{{dateISO8601}}` | タイムゾーンを含む日時（`time`の属性用） |
| `{{tags}}` / `{{tagText}}` | タグのspan要素 / 元のタグ文字列 |
| `{{siteTitle}}` / `{{siteDescription}}` | アプリの設定に保存したサイト名・説明 |

本文以外はHTMLをエスケープして挿入します。テンプレートや記事のJavaScript・フォーム送信・リンク移動は実行しません。コメント欄やメニューの操作は実際のサイトで確認してください。`base`、自動転送、未知の置換項目を含むテンプレートは設定時に拒否します。

通常の `![写真](/images/trip/photo.jpeg)` も公開サイトのルートから読み込みます。これらの既存画像を、アプリで管理する添付写真へ自動変換することはありません。アプリが追加した写真は、公開前から端末内のコピーで表示します。

`config/sfuji-diary.json` と `config/sfuji-journey.json` は、sfuji.orgの保存形式と記事ページのHTML・CSSを使う設定例です。検証元のテーマは `fe21042936871bbea0cca0432163ee4709bdf2fa` 時点です。サイトのテーマを変更した場合はテンプレートも更新してください。

この方法は記事ページの見た目を合わせるものです。Astro／Jekyll／HugoをiPhone内で実行する機能ではありません。Liquid・shortcode・MDXの独自部品、構文強調など、サイト固有の本文処理は別途対応が必要です。

記事中の属性を持たない `br` / `hr` は、そのまま改行・区切りとして表示します。任意のHTMLは実行せず、その他のHTMLは文字として表示します。確認済みのSpotify埋め込みは専用の処理で表示します。

CIの回帰テストは標準設定で実行し、設定違いはテスト内で渡して検証しています。
