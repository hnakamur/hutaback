hutaback
========

これは私が Zig の勉強のために書いてみた HTTP サーバです。
プロダクション用途ではありません。

[coilhq/tigerbeetle: A distributed financial accounting database designed for mission critical safety and performance to power the future of financial services.](https://github.com/coilhq/tigerbeetle) の開発者の方が [Issues · ziglang/zig](https://github.com/ziglang/zig/issues/8224) で [コメント](https://github.com/ziglang/zig/issues/8224#issuecomment-847669956) されていた中に当初 async + io_uring で開発していたけれど結局コールバック + io_uring に変えたという話がありました。

これをみて [coilhq/tigerbeetle](https://github.com/coilhq/tigerbeetle) の IO のコードを [hnakamur/tigerbeetle-io: The examples using TigerBeetle IO struct](https://github.com/hnakamur/tigerbeetle-io) に切り出して、それを使ってコールバック + io_uring でHTTPサーバを書いてみたというものです。

Zig を学び始めたころに書いたので、勝手がわからずいろいろ試行錯誤した状態のままになっています。

テストでは以下のように2つ警告が出ますがこれは想定通りです（しかしこれももっと良い方法を考えたいところ）。

```
$ zig build test
Test [9/103] fields.test "FieldLineIterator - bad usage"... [http] (warn): FieldLineIterator must be initialized with valid fields in buf.
Test [11/103] fields.test "FieldNameLineIterator - bad usage"... [http] (warn): FieldNameLineIterator must be initialized with valid fields in buf.
All 103 tests passed.
No tests to run.
No tests to run.
```

```
$ zig version
0.10.0-dev.2998+a45592715
```
