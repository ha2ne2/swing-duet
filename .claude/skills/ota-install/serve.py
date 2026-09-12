# OTA 配信用の最小サーバー（ota-install.sh から起動）。引数：配るディレクトリ、ポート。
# 127.0.0.1 だけに束ねる（外からの着信を受けないので macOS のファイアウォールの許可画面が出ない。外へは cloudflared が出す）。
# iOS のインストーラは manifest.plist を text/xml、IPA を application/octet-stream で受け取るので型を固定する
import http.server
import sys

directory, port = sys.argv[1], int(sys.argv[2])


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {".plist": "text/xml", ".ipa": "application/octet-stream", ".html": "text/html; charset=utf-8", "": "application/octet-stream"}

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)

    def list_directory(self, path):   # 一覧は出さない
        self.send_error(404)
        return None


http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
