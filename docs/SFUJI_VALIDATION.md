# sfuji.org への適応検証

2026-10-05、cocoWriter 0.2.0 / Build 2にテーマ指定のプレビューを追加して検証。この検証時点のプロジェクト名はPagesWriterで、GitHub公開に向けてcocoWriterへ改名した。

## 検証対象と設定

公開ソース [sfujibijutsukan/sfujibijutsukan.github.io](https://github.com/sfujibijutsukan/sfujibijutsukan.github.io) の `fe21042936871bbea0cca0432163ee4709bdf2fa` を使用。実際のリポジトリや公開サイトへの書き込みは行っていない。

| 項目 | 日記用 | 旅行記事用 |
| --- | --- | --- |
| 設定例 | `config/sfuji-diary.json` | `config/sfuji-journey.json` |
| 記事保存先 | `src/content/diary` | `src/content/journey` |
| 画像保存先 | `public/images/blog/diary` | `public/images/blog/journey` |
| 画像公開パス | `/images/blog/diary` | `/images/blog/journey` |
| Front Matter | YAML、説明文は任意 | 同左 |
| 新規記事の固定項目 | `draft: false` | 同左 |
| 除外する記事 | `_index.md`, `_template.md` | 同左 |
| プレビュー | サイトの日記ページのHTML・CSS | サイトの旅行記事ページのHTML・CSS |

端末の公開先は owner `sfujibijutsukan`、repository `sfujibijutsukan.github.io`、branch `main`、URL `https://sfuji.org/` とした。公開ブランチは [Pagesワークフロー](https://github.com/sfujibijutsukan/sfujibijutsukan.github.io/blob/fe21042936871bbea0cca0432163ee4709bdf2fa/.github/workflows/pages.yml) と一致。設定の適用方法は [記事形式とプレビュー](content-format.md) を参照。

## 確認したこと

- 日記257件を公開ソースから取得し、模擬GitHub API経由でアプリの実際の読み込み処理に渡した。説明文なしの記事を含めて読み込み成功。テンプレートと他のカテゴリは除外された。
- 読み込んだ記事のMarkdownは未編集時に元ファイルと完全一致。タイトル・本文の編集後も元の保存先と `draft` の値を保持し、再読み込みできた。
- 写真付き新規記事は説明文なしで入力検査を通過し、`draft: false`、指定した画像保存先・公開パスが生成された。記事とJPEGを同じコミットに含める要求、および `main` への非強制更新を模擬APIで確認した。
- 日記用・旅行記事用のアプリが生成した記事とJPEGをサイトソースの独立コピーへ入れ、実際のAstroビルドが成功（178ページ）。両方の記事ルート、タイトル、画像URL、公開されるJPEGファイルの存在を確認した。
- DeviceHubの専用iOS 27 Simulatorで、日記用ビルドの編集画面とテーマ付きプレビューを操作。sfuji.orgのヘッダー・CSS、日付・タイトル・本文、公開前のローカル写真を目視確認した。
- 旅行記事用ビルドで実際の `fukuoka2026.md` を開き、サイトのテーマ・タグ・HTML改行と、既存の `/images/blog/journey/fukuoka2026/airplane.jpeg` が表示されることをDeviceHubで確認した。
- 追加した機能を含む標準設定のXCTest **113件成功、失敗0件**。設定選択ツールのテスト **6件成功**。テーマの置換・エスケープ、日時、既存画像URL、管理画像との分離、記事中の安全な `br` / `hr` の表示を確認した。
- 設定別の検証は日記用4件成功。最終版の旅行記事用では、プレビューのテスト4件と公開ソース・模擬APIのテスト4件、合計8件が成功した。

プレビューはサイトのHTML・CSSを同梱して本文を差し替える方式。プレビューのための記事公開は不要。テーマだけを変えても保存済み記事の保存先・Front Matter設定は変わらない。

## 残る制約

- 既存記事の `draft: true` は保持される。アプリ内に公開フラグの切り替えはなく、この値のままGitHubへ保存してもサイトには表示されない。「投稿済み」はGitHub上にファイルが存在するという意味で、サイトの公開状態とは一致しない場合がある。
- カテゴリは設定画面で複数登録し、保存先・Front Matter形式・項目名などをカテゴリごとに変更できる。保存済みの記事は元の設定を保持する。プレビューテーマはアプリ共通で、カテゴリ別のテーマ切り替えはない。上記の検証記録は従来のカテゴリ別ビルドについての記録で、複数カテゴリによる実サイトビルドの追加検証はまだ行っていない。
- 新規記事の名前は `ios-{id}.md`。既存の `YYYYMMDD.md` は編集時に保持するが、サイトの日次作成スクリプトと同じ名前で自動作成する機能はない。
- 既存の一般的な画像は公開URLから表示する。添付画像としての管理やオフライン用の自動取り込みは行わない。
- テーマの見た目は合わせられるが、Astro・MDX・Liquid・Hugo shortcodeを端末内で実行する機能ではない。コメント送信、メニューのJavaScript、独自部品、構文強調は公開サイトで確認する。
- 実際のGitHubトークンによる送信とPagesデプロイ、iPhone実機、iOS 17での動作は未確認。

取得した本文、サイトコピー、実行ログ、専用ビルド、DeviceHubの画像はGit対象外の `.validation-cache/sfuji/` に保存。元のアプリのソース・設定等53ファイルは作業開始前のSHA-256と一致している。
