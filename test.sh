cargo build --release
./target/release/fluxa examples/fir.fx            # 跑檔案內所有 test
./target/release/fluxa examples/gemm.fx --stats   # 另外印出每條通道的 token 數與 FIFO 最大佔用
./target/release/fluxa examples/mac.fx --trace    # 印出每一次 send / recv
./target/release/fluxa examples/fir.fx --test fir_impulse
./target/release/fluxa examples/fir.fx --list
cargo test --release                              # 範例回歸測試（含 100 次死結偵測重複測試）