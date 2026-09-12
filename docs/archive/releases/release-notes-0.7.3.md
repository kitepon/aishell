# 0.7.3

npm公開をGitHub ActionsのTrusted Publishingへ移した。mainへ反映した版のタグを送ると、GitHub管理のMacで配布物を作成・検査し、OIDCで自動認証してnpmへ直接公開する。公開後はGitHub Releaseも作成する。

公開ごとのTouch ID操作と長期npm tokenは不要になる。AIShellの操作機能とAI設定は従来どおり利用できる。
