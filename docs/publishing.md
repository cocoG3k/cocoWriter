# オープンソースプロジェクトとして公開する

公開するアプリのリポジトリと、利用者が記事を投稿するブログのリポジトリは別々に管理します。

cocoWriterの公開リポジトリは [cocoG3k/cocoWriter](https://github.com/cocoG3k/cocoWriter) です。[GitHub Actions](https://github.com/cocoG3k/cocoWriter/actions)でiOSとブログの検証を行います。

## アプリのソースを公開する

1. この `cocoWriter/` ディレクトリをGitHub Desktop等へ追加します。`.gitignore` によりビルドキャッシュ・IPA・端末のユーザー設定・ローカルの検証ログを除外します。
2. `LICENSE` はMITとして用意しています。README、第三者ライセンス、ロックファイル、CI、投稿先未設定のアプリが揃っています。
3. Xcodeで自分の署名チームを設定していた場合は、公開する `project.pbxproj` の `DEVELOPMENT_TEAM` を空へ戻します。証明書やプロビジョニングプロファイル、トークンを追加しないでください。
4. `python3 tools/check-project.py` で配布対象を確認します。
5. GitHubで新しいPublicリポジトリを作成し、このプロジェクトをpushします。リポジトリ名は `cocoWriter` 以外でも構いません。既存の個人ブログのリポジトリへ上書きする必要はありません。

このプロジェクトのルートにあるActionsは検証用です。アプリ自体をブラウザ向けに公開するものではありません。

## ソースZIPを配る

```sh
python3 tools/package-source.py
```

`releases/cocoWriter-0.2.1-source.zip` と `releases/cocoWriter-0.2.1-blog-template.zip` を生成します。ファイル名のバージョンはXcodeプロジェクトの設定から取得します。ソースZIPにはアプリ・テンプレート・ドキュメントが入り、ブログZIPは利用者のブログリポジトリへ配置する雛形です。ビルド生成物、個人の検証ログ、Gitの管理情報は入りません。

実行にはGitリポジトリが必要です。ソースZIPを展開して利用する場合は、プロジェクトのルートで `git init -b main` を実行してから使えます。ローカルで作成したファイルもGitの除外ルールに従ってパッケージへ入るため、配布前に変更内容を確認してください。

ソースZIPはブログの公開を自動では行いません。利用者は自分のブログリポジトリを作り、Pagesとアプリの接続設定を用意します。
