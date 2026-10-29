// ════════════════════════════════════════════════════════════════════════════
//  RV64IM 處理器（Fluxa）— v0.3 里程碑 M1
//
//   Fetch ──(pc,inst)──► Decode ──(pc,inst,cls,a,b)──► Execute ──► Mem ──► WB
//
//   與 rv32i 相同的骨架：四級 task + 深度 1 FIFO、Decode 持暫存器檔與記分板、
//   分支/JALR 停等 redirect、ECALL 傾印狀態。差異：
//   • 資料路徑 64 位元；新增 W 型指令（結果符號擴展）與 M 擴充（含 W 型變體）。
//   • 精確整數上限 120 位元 ⇒ 64 位元左移分兩段（sll64）、
//     64×64 乘積用 32 位元學校乘法分塊（mul_hi_lo）。
// ════════════════════════════════════════════════════════════════════════════

// ── 參數 ────────────────────────────────────────────────────────────────────
const IWORDS: u32 = 64;               // 指令記憶體字數（32 位元字）
const DWORDS: u32 = 64;               // 資料記憶體字數（64 位元字 = 512 位元組）
const MMIO_OUT: u32 = 0x10000000;     // 對此位址 SW → 送一個 token 到 io 通道
const FETCH_LIMIT: u32 = 3000;        // 看門狗：超過就當作非法指令陷阱
const MAX_INFLIGHT: u32 = 16;         // 記分板排空迴圈的上界
const WB_DEPTH: u32 = 8;              // 寫回 FIFO 深度

// 傾印格式
const DUMP_LEN: u32 = 36;
const D_CAUSE: u32 = 0;               // 0 = ECALL, 1 = EBREAK, 2 = 非法指令／看門狗
const D_PC: u32 = 1;
const D_RETIRED: u32 = 2;
const D_STALLS: u32 = 3;
const D_X: u32 = 4;                   // x0..x31

// 指令類別（classify 的回傳值）
const C_ILLEGAL: u4 = 0;
const C_LUI: u4 = 1;
const C_AUIPC: u4 = 2;
const C_JAL: u4 = 3;
const C_JALR: u4 = 4;
const C_BRANCH: u4 = 5;
const C_LOAD: u4 = 6;
const C_STORE: u4 = 7;
const C_OPIMM: u4 = 8;
const C_OP: u4 = 9;
const C_OPIMM32: u4 = 10;             // OP-IMM-32（addiw/slliw/srliw/sraiw）
const C_OP32: u4 = 11;                // OP-32（addw/subw/sllw/srlw/sraw）
const C_M: u4 = 12;                   // M 擴充（64 位元）
const C_M32: u4 = 13;                 // M 擴充 W 型（mulw/divw/…）
const C_FENCE: u4 = 14;
const C_HALT: u4 = 15;

// ════════════════════════════════════════════════════════════════════════════
//  組譯器
// ════════════════════════════════════════════════════════════════════════════
fn enc_r(f7: u7, rs2: u5, rs1: u5, f3: u3, rd: u5, op: u7) -> u32 {
    (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
}
fn enc_i(imm: i12, rs1: u5, f3: u3, rd: u5, op: u7) -> u32 {
    (imm.wrap::<u12>() << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
}
fn enc_s(imm: i12, rs2: u5, rs1: u5, f3: u3, op: u7) -> u32 {
    let u = imm.wrap::<u12>();
    (u[11:5] << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (u[4:0] << 7) | op
}
fn enc_b(imm: i13, rs2: u5, rs1: u5, f3: u3, op: u7) -> u32 {
    assert imm[0:0] == 0, "branch offset must be even";
    let u = imm.wrap::<u13>();
    (u[12:12] << 31) | (u[10:5] << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12)
        | (u[4:1] << 8) | (u[11:11] << 7) | op
}
fn enc_u(imm: u20, rd: u5, op: u7) -> u32 {
    (imm << 12) | (rd << 7) | op
}
fn enc_j(imm: i21, rd: u5, op: u7) -> u32 {
    assert imm[0:0] == 0, "jump offset must be even";
    let u = imm.wrap::<u21>();
    (u[20:20] << 31) | (u[10:1] << 21) | (u[11:11] << 20) | (u[19:12] << 12) | (rd << 7) | op
}

const OP: u7 = 0x33;
const OP32: u7 = 0x3B;
const OPIMM: u7 = 0x13;
const OPIMM32: u7 = 0x1B;
const LOAD: u7 = 0x03;
const STORE: u7 = 0x23;
const BRANCH: u7 = 0x63;

fn add(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0, rs2, rs1, 0, rd, OP) }
fn sub(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0x20, rs2, rs1, 0, rd, OP) }
fn sll(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0, rs2, rs1, 1, rd, OP) }
fn slt(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0, rs2, rs1, 2, rd, OP) }
fn sltu(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0, rs2, rs1, 3, rd, OP) }
fn xor(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0, rs2, rs1, 4, rd, OP) }
fn srl(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0, rs2, rs1, 5, rd, OP) }
fn sra(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0x20, rs2, rs1, 5, rd, OP) }
fn or(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0, rs2, rs1, 6, rd, OP) }
fn and(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0, rs2, rs1, 7, rd, OP) }

fn addw(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0, rs2, rs1, 0, rd, OP32) }
fn subw(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0x20, rs2, rs1, 0, rd, OP32) }
fn sllw(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0, rs2, rs1, 1, rd, OP32) }
fn srlw(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0, rs2, rs1, 5, rd, OP32) }
fn sraw(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(0x20, rs2, rs1, 5, rd, OP32) }

fn mul(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(1, rs2, rs1, 0, rd, OP) }
fn mulh(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(1, rs2, rs1, 1, rd, OP) }
fn mulhsu(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(1, rs2, rs1, 2, rd, OP) }
fn mulhu(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(1, rs2, rs1, 3, rd, OP) }
fn div(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(1, rs2, rs1, 4, rd, OP) }
fn divu(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(1, rs2, rs1, 5, rd, OP) }
fn rem(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(1, rs2, rs1, 6, rd, OP) }
fn remu(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(1, rs2, rs1, 7, rd, OP) }

fn mulw(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(1, rs2, rs1, 0, rd, OP32) }
fn divw(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(1, rs2, rs1, 4, rd, OP32) }
fn divuw(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(1, rs2, rs1, 5, rd, OP32) }
fn remw(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(1, rs2, rs1, 6, rd, OP32) }
fn remuw(rd: u5, rs1: u5, rs2: u5) -> u32 { enc_r(1, rs2, rs1, 7, rd, OP32) }

fn addi(rd: u5, rs1: u5, imm: i12) -> u32 { enc_i(imm, rs1, 0, rd, OPIMM) }
fn slti(rd: u5, rs1: u5, imm: i12) -> u32 { enc_i(imm, rs1, 2, rd, OPIMM) }
fn sltiu(rd: u5, rs1: u5, imm: i12) -> u32 { enc_i(imm, rs1, 3, rd, OPIMM) }
fn xori(rd: u5, rs1: u5, imm: i12) -> u32 { enc_i(imm, rs1, 4, rd, OPIMM) }
fn ori(rd: u5, rs1: u5, imm: i12) -> u32 { enc_i(imm, rs1, 6, rd, OPIMM) }
fn andi(rd: u5, rs1: u5, imm: i12) -> u32 { enc_i(imm, rs1, 7, rd, OPIMM) }
fn slli(rd: u5, rs1: u5, sh: u6) -> u32 { enc_i(sh, rs1, 1, rd, OPIMM) }
fn srli(rd: u5, rs1: u5, sh: u6) -> u32 { enc_i(sh, rs1, 5, rd, OPIMM) }
fn srai(rd: u5, rs1: u5, sh: u6) -> u32 { enc_i(0x400 + sh, rs1, 5, rd, OPIMM) }

fn addiw(rd: u5, rs1: u5, imm: i12) -> u32 { enc_i(imm, rs1, 0, rd, OPIMM32) }
fn slliw(rd: u5, rs1: u5, sh: u5) -> u32 { enc_i(sh, rs1, 1, rd, OPIMM32) }
fn srliw(rd: u5, rs1: u5, sh: u5) -> u32 { enc_i(sh, rs1, 5, rd, OPIMM32) }
fn sraiw(rd: u5, rs1: u5, sh: u5) -> u32 { enc_i(0x400 + sh, rs1, 5, rd, OPIMM32) }

fn lb(rd: u5, rs1: u5, off: i12) -> u32 { enc_i(off, rs1, 0, rd, LOAD) }
fn lh(rd: u5, rs1: u5, off: i12) -> u32 { enc_i(off, rs1, 1, rd, LOAD) }
fn lw(rd: u5, rs1: u5, off: i12) -> u32 { enc_i(off, rs1, 2, rd, LOAD) }
fn ld(rd: u5, rs1: u5, off: i12) -> u32 { enc_i(off, rs1, 3, rd, LOAD) }
fn lbu(rd: u5, rs1: u5, off: i12) -> u32 { enc_i(off, rs1, 4, rd, LOAD) }
fn lhu(rd: u5, rs1: u5, off: i12) -> u32 { enc_i(off, rs1, 5, rd, LOAD) }
fn lwu(rd: u5, rs1: u5, off: i12) -> u32 { enc_i(off, rs1, 6, rd, LOAD) }

fn sb(rs2: u5, rs1: u5, off: i12) -> u32 { enc_s(off, rs2, rs1, 0, STORE) }
fn sh(rs2: u5, rs1: u5, off: i12) -> u32 { enc_s(off, rs2, rs1, 1, STORE) }
fn sw(rs2: u5, rs1: u5, off: i12) -> u32 { enc_s(off, rs2, rs1, 2, STORE) }
fn sd(rs2: u5, rs1: u5, off: i12) -> u32 { enc_s(off, rs2, rs1, 3, STORE) }

fn beq(rs1: u5, rs2: u5, off: i13) -> u32 { enc_b(off, rs2, rs1, 0, BRANCH) }
fn bne(rs1: u5, rs2: u5, off: i13) -> u32 { enc_b(off, rs2, rs1, 1, BRANCH) }
fn blt(rs1: u5, rs2: u5, off: i13) -> u32 { enc_b(off, rs2, rs1, 4, BRANCH) }
fn bge(rs1: u5, rs2: u5, off: i13) -> u32 { enc_b(off, rs2, rs1, 5, BRANCH) }
fn bltu(rs1: u5, rs2: u5, off: i13) -> u32 { enc_b(off, rs2, rs1, 6, BRANCH) }
fn bgeu(rs1: u5, rs2: u5, off: i13) -> u32 { enc_b(off, rs2, rs1, 7, BRANCH) }

fn lui(rd: u5, imm: u20) -> u32 { enc_u(imm, rd, 0x37) }
fn auipc(rd: u5, imm: u20) -> u32 { enc_u(imm, rd, 0x17) }
fn jal(rd: u5, off: i21) -> u32 { enc_j(off, rd, 0x6F) }
fn jalr(rd: u5, rs1: u5, off: i12) -> u32 { enc_i(off, rs1, 0, rd, 0x67) }

fn ecall() -> u32 { 0x00000073 }
fn ebreak() -> u32 { 0x00100073 }
fn fence() -> u32 { 0x0FF0000F }
fn nop() -> u32 { addi(0, 0, 0) }

/// 載入 32 位元常數（lui + addi 補償符號擴展）：結果 = sext32(imm)
fn li(rd: u5, imm: u32) -> [u32; 2] {
    let hi = ((imm + 0x800) >> 12) & 0xFFFFF;
    let lo = (imm & 0xFFF).wrap::<i12>();
    [lui(rd, hi), addi(rd, rd, lo)]
}

/// 載入任意 64 位元常數：高 32 位（sext32 後左移 32）+ 低 32 位（零擴展）相加。
/// 注意 rd 不可為 31（內部借用 rd+1 作暫存）。
fn li64(rd: u5, hi: u32, lo: u32) -> [u32; 8] {
    let t = rd + 1;
    concat(li(rd, hi), concat([
        slli(rd, rd, 32)],
        concat(li(t, lo), concat([
        slli(t, t, 32),
        srli(t, t, 32),
        add(rd, rd, t)], []))))
}

// ════════════════════════════════════════════════════════════════════════════
//  解碼
// ════════════════════════════════════════════════════════════════════════════
comb fn imm_i(inst: u32) -> i32 { inst[31:20].wrap::<i12>() }
comb fn imm_s(inst: u32) -> i32 { ((inst[31:25] << 5) | inst[11:7]).wrap::<i12>() }
comb fn imm_b(inst: u32) -> i32 {
    ((inst[31:31] << 12) | (inst[7:7] << 11) | (inst[30:25] << 5) | (inst[11:8] << 1)).wrap::<i13>()
}
comb fn imm_u(inst: u32) -> u32 { inst[31:12] << 12 }
comb fn imm_j(inst: u32) -> i32 {
    ((inst[31:31] << 20) | (inst[19:12] << 12) | (inst[20:20] << 11) | (inst[30:21] << 1)).wrap::<i21>()
}

/// 指令分類，同時是合法性檢查。注意 RV64 的 SLLI/SRLI/SRAI 移位量為 6 位元，
/// 合法性要檢查 inst[31:26]（imm[11:6]），不是 7 位元 funct7。
comb fn classify(inst: u32) -> u4 {
    let op = inst[6:0];
    let f3 = inst[14:12];
    let f7 = inst[31:25];
    let f6 = inst[31:26];               // RV64 立即移位的 6 位元操作碼欄
    match op {
        0x37 => C_LUI,
        0x17 => C_AUIPC,
        0x6F => C_JAL,
        0x67 => if f3 == 0 { C_JALR } else { C_ILLEGAL },
        0x63 => if f3 == 2 || f3 == 3 { C_ILLEGAL } else { C_BRANCH },
        0x03 => if f3 == 7 { C_ILLEGAL } else { C_LOAD },        // LB..LWU（0..6）
        0x23 => if f3 > 3 { C_ILLEGAL } else { C_STORE },        // SB..SD（0..3）
        0x13 => if f3 == 1 {
                    if f6 == 0 { C_OPIMM } else { C_ILLEGAL }    // SLLI
                } else if f3 == 5 {
                    if f6 == 0 || f6 == 0x10 { C_OPIMM } else { C_ILLEGAL }   // SRLI/SRAI
                } else { C_OPIMM },
        0x1B => if f3 == 0 { C_OPIMM32 }                         // ADDIW
                else if f3 == 1 { if f7 == 0 { C_OPIMM32 } else { C_ILLEGAL } }
                else if f3 == 5 { if f7 == 0 || f7 == 0x20 { C_OPIMM32 } else { C_ILLEGAL } }
                else { C_ILLEGAL },
        0x33 => if f7 == 0 { C_OP }
                else if f7 == 0x01 { C_M }
                else if f7 == 0x20 && (f3 == 0 || f3 == 5) { C_OP }
                else { C_ILLEGAL },
        0x3B => if f7 == 0x01 {
                    if f3 == 0 || f3 > 3 { C_M32 } else { C_ILLEGAL }   // MULW/DIVW/DIVUW/REMW/REMUW
                } else if f3 == 0 {
                    if f7 == 0 || f7 == 0x20 { C_OP32 } else { C_ILLEGAL }   // ADDW/SUBW
                } else if f3 == 1 {
                    if f7 == 0 { C_OP32 } else { C_ILLEGAL }            // SLLW
                } else if f3 == 5 {
                    if f7 == 0 || f7 == 0x20 { C_OP32 } else { C_ILLEGAL }   // SRLW/SRAW
                } else { C_ILLEGAL },
        0x0F => C_FENCE,
        0x73 => if inst == 0x00000073 || inst == 0x00100073 { C_HALT } else { C_ILLEGAL },
        _ => C_ILLEGAL,
    }
}

comb fn uses_rs1(c: u4) -> bool {
    c == C_JALR || c == C_BRANCH || c == C_LOAD || c == C_STORE
        || c == C_OPIMM || c == C_OP || c == C_OPIMM32 || c == C_OP32 || c == C_M || c == C_M32
}
comb fn uses_rs2(c: u4) -> bool {
    c == C_BRANCH || c == C_STORE || c == C_OP || c == C_OP32 || c == C_M || c == C_M32
}
comb fn writes_rd(c: u4) -> bool {
    c == C_LUI || c == C_AUIPC || c == C_JAL || c == C_JALR || c == C_LOAD
        || c == C_OPIMM || c == C_OP || c == C_OPIMM32 || c == C_OP32 || c == C_M || c == C_M32
}
comb fn trap_cause(inst: u32) -> u2 {
    if inst == 0x00000073 { 0 } else if inst == 0x00100073 { 1 } else { 2 }
}

// ════════════════════════════════════════════════════════════════════════════
//  ALU（64 位元）與 M 擴充
// ════════════════════════════════════════════════════════════════════════════

/// 64 位元左移。精確整數上限 120 位元，2^64 << 63 會爆，
/// 所以分兩次移位、中間 wrap 回 u64。
comb fn sll64(a: u64, sh: u6) -> u64 {
    ((a << (sh >> 1)).wrap::<u64>() << (sh - (sh >> 1))).wrap::<u64>()
}

/// 64×64 → 128 位元乘積的 (hi, lo)。
/// 積最大近 2^128，超過精確整數上限，以 32 位元學校乘法分塊：
///   a·b = al·bl + (ah·bl + al·bh)·2^32 + ah·bh·2^64
comb fn mul_hi_lo(a: u64, b: u64) -> (u64, u64) {
    let ah = a[63:32];
    let al = a[31:0];
    let bh = b[63:32];
    let bl = b[31:0];
    let p0 = al * bl;                        // < 2^64
    let p1 = ah * bl;                        // < 2^64
    let p2 = al * bh;                        // < 2^64
    let p3 = ah * bh;                        // < 2^64
    let sum_mid = p1 + p2;                   // < 2^65（精確值）
    let mid = sum_mid.wrap::<u64>();
    let s_lo = p0 + ((mid & 0xFFFFFFFF) << 32);   // < 2^65（精確值）
    let lo = s_lo.wrap::<u64>();
    let hi = (sum_mid >> 32) + p3 + (s_lo >> 64); // < 2^64（可證）
    (hi, lo)
}

/// M 擴充（64 位元）。除以零與 overflow 的特殊值依 spec 手動處理
/// （模擬器的 `/` `%` 對零除會直接報錯，且語意恰好是 trunc toward zero，與 RISC-V 一致）。
/// MULH/MULHSU 由無號積修正：a_s·b_s = a_u·b_u − a_u·2^64·sb − b_u·2^64·sa（mod 2^128）。
comb fn alu_m(f3: u3, a: u64, b: u64) -> u64 {
    let (hi, lo) = mul_hi_lo(a, b);
    let sa = a[63:63];
    let sb = b[63:63];
    match f3 {
        0 => lo,                                             // MUL
        1 => (hi - (if sb == 1 { a } else { 0 })
                 - (if sa == 1 { b } else { 0 })).wrap::<u64>(), // MULH（有號×有號）
        2 => (hi - (if sa == 1 { b } else { 0 })).wrap::<u64>(), // MULHSU（有號×無號）
        3 => hi,                                             // MULHU
        4 => if b == 0 { 0xFFFFFFFFFFFFFFFF }
             else { (a.wrap::<i64>() / b.wrap::<i64>()).wrap::<u64>() },   // DIV
        5 => if b == 0 { 0xFFFFFFFFFFFFFFFF } else { a / b },             // DIVU
        6 => if b == 0 { a } else { (a.wrap::<i64>() % b.wrap::<i64>()).wrap::<u64>() }, // REM
        _ => if b == 0 { a } else { a % b },                              // REMU
    }
}

/// M 擴充 W 型：對 32 位元值運算，結果符號擴展到 64 位元。
/// 32 位元乘法積 < 2^64，不會碰到 120 位元上限，可直接算。
comb fn alu_m_w(f3: u3, a: u64, b: u64) -> u64 {
    let a32 = a.wrap::<i32>();
    let b32 = b.wrap::<i32>();
    let au32 = a.wrap::<u32>();
    let bu32 = b.wrap::<u32>();
    match f3 {
        0 => (au32 * bu32).wrap::<i32>().wrap::<u64>(),       // MULW
        4 => if b32 == 0 { 0xFFFFFFFFFFFFFFFF }
             else { (a32 / b32).wrap::<i32>().wrap::<u64>() },             // DIVW
        5 => if bu32 == 0 { 0xFFFFFFFFFFFFFFFF }
             else { (au32 / bu32).wrap::<i32>().wrap::<u64>() },           // DIVUW
        6 => if b32 == 0 { a32.wrap::<u64>() }
             else { (a32 % b32).wrap::<i32>().wrap::<u64>() },             // REMW
        _ => if bu32 == 0 { a32.wrap::<u64>() }
             else { (au32 % bu32).wrap::<i32>().wrap::<u64>() },           // REMUW
    }
}

/// 整數 ALU（64 位元）：f3 選運算，alt 區分 ADD/SUB 與 SRL/SRA
comb fn alu(f3: u3, alt: bit, a: u64, b: u64) -> u64 {
    let sh = b[5:0];
    match f3 {
        0 => if alt == 1 { (a - b).wrap::<u64>() } else { (a + b).wrap::<u64>() },
        1 => sll64(a, sh),
        2 => (a.wrap::<i64>() < b.wrap::<i64>()) as u64,
        3 => (a < b) as u64,
        4 => a ^ b,
        5 => if alt == 1 { (a.wrap::<i64>() >> sh).wrap::<u64>() } else { a >> sh },
        6 => a | b,
        _ => a & b,
    }
}

/// W 型整數 ALU：先在 32 位元內運算，結果符號擴展
comb fn alu_w(f3: u3, alt: bit, a: u64, b: u64) -> u64 {
    let sh = b[4:0];
    let a32 = a.wrap::<i32>();
    match f3 {
        0 => if alt == 1 { (a32 - b.wrap::<i32>()).wrap::<i32>().wrap::<u64>() }
             else { (a32 + b.wrap::<i32>()).wrap::<i32>().wrap::<u64>() },
        1 => (a.wrap::<u32>() << sh).wrap::<i32>().wrap::<u64>(),       // SLLW
        5 => if alt == 1 { (a32 >> sh).wrap::<i32>().wrap::<u64>() }    // SRAW
             else { (a.wrap::<u32>() >> sh).wrap::<i32>().wrap::<u64>() },   // SRLW（結果仍要 sext32）
        _ => 0,
    }
}

/// W 型立即 ALU（ADDIW/SLLIW/SRLIW/SRAIW）；imm 已符號擴展成 64 位元
comb fn alu_w_imm(f3: u3, alt: bit, a: u64, imm: u64) -> u64 {
    let sh = imm[4:0];
    let a32 = a.wrap::<i32>();
    match f3 {
        0 => (a32 + imm.wrap::<i32>()).wrap::<i32>().wrap::<u64>(),     // ADDIW
        1 => (a.wrap::<u32>() << sh).wrap::<i32>().wrap::<u64>(),       // SLLIW
        5 => if alt == 1 { (a32 >> sh).wrap::<i32>().wrap::<u64>() }    // SRAIW
             else { (a.wrap::<u32>() >> sh).wrap::<i32>().wrap::<u64>() },   // SRLIW（結果仍要 sext32）
        _ => 0,
    }
}

comb fn branch_taken(f3: u3, a: u64, b: u64) -> bool {
    match f3 {
        0 => a == b,
        1 => a != b,
        4 => a.wrap::<i64>() < b.wrap::<i64>(),
        5 => a.wrap::<i64>() >= b.wrap::<i64>(),
        6 => a < b,
        _ => a >= b,
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  管線
// ════════════════════════════════════════════════════════════════════════════

/// 取指：持有指令記憶體與 pc。
task Fetch(prog: [u32; IWORDS], to_dec: out chan<(u32, u32)>, redirect: in chan<u64>) {
    carry pc: u64 = 0;
    serial for _ in 0..FETCH_LIMIT {
        let word = pc >> 2;
        let inst = if (pc & 3) == 0 && word < IWORDS { prog[word] } else { 0 };   // 越界／未對齊 → 0 = 非法
        to_dec.send((pc, inst));
        let c = classify(inst);
        if c == C_HALT || c == C_ILLEGAL {
            return;
        }
        if c == C_JAL {
            pc = (pc + imm_j(inst)).wrap::<u64>();
        } else if c == C_JALR || c == C_BRANCH {
            pc = redirect.recv();
        } else {
            pc = (pc + 4).wrap::<u64>();
        }
    }
    to_dec.send((pc, 0));     // 看門狗到期：以非法指令陷阱收場
}

/// 解碼 + 暫存器檔 + 記分板
task Decode(ifq: in chan<(u32, u32)>,
            to_ex: out chan<(u32, u32, u4, u64, u64)>,
            wbq: in chan<(u5, u64)>,
            dump: out chan<u64>) {
    let mut x: [u64; 32] = [0; 32];
    let mut pend: [u4; 32] = [0; 32];
    let mut inflight: u5 = 0;
    let mut retired: u64 = 0;
    let mut stalls: u64 = 0;

    for (pc, inst) in ifq {
        let c = classify(inst);
        let rd = inst[11:7];
        let rs1 = inst[19:15];
        let rs2 = inst[24:20];
        let u1 = uses_rs1(c);
        let u2 = uses_rs2(c);

        // 資料相依：等到來源暫存器沒有未完成的寫入
        for _ in 0..MAX_INFLIGHT {
            if (u1 && pend[rs1] != 0) || (u2 && pend[rs2] != 0) {
                let (r, v) = wbq.recv();
                x[r] = v;
                pend[r] = pend[r] - 1;
                inflight = inflight - 1;
                stalls += 1;
            }
        }

        // 陷阱：排空管線、傾印狀態、結束
        if c == C_HALT || c == C_ILLEGAL {
            for _ in 0..MAX_INFLIGHT {
                if inflight != 0 {
                    let (r, v) = wbq.recv();
                    x[r] = v;
                    pend[r] = pend[r] - 1;
                    inflight = inflight - 1;
                }
            }
            dump.send(trap_cause(inst));
            dump.send(pc);
            dump.send(retired);
            dump.send(stalls);
            for i in 0..32 { dump.send(x[i]); }
            return;
        }

        if writes_rd(c) && rd != 0 {
            pend[rd] = pend[rd] + 1;
            inflight = inflight + 1;
        }
        retired += 1;
        to_ex.send((pc, inst, c, x[rs1], x[rs2]));
    }
}

/// 執行：ALU、分支判斷、位址計算。分支與 JALR 把下一個 pc 送回 Fetch。
task Execute(from_dec: in chan<(u32, u32, u4, u64, u64)>,
             to_mem: out chan<(u2, u5, u64, u64, u64, u3)>,
             redirect: out chan<u64>) {
    for (pc, inst, c, a, b) in from_dec {
        let rd = inst[11:7];
        let f3 = inst[14:12];
        let alt = inst[30:30];
        let link = (pc + 4).wrap::<u64>();

        // kind：0 = 無寫回，1 = 寫回 val，2 = 載入（寫回 Mem 讀到的值），3 = 儲存
        let (kind, val, addr, sdata) = match c {
            C_LUI => (1, imm_u(inst).wrap::<i32>().wrap::<u64>(), 0, 0),
            C_AUIPC => (1, (pc + imm_u(inst).wrap::<i32>()).wrap::<u64>(), 0, 0),
            C_JAL => (1, link, 0, 0),
            C_JALR => {
                redirect.send(((a + imm_i(inst)).wrap::<u64>()) & 0xFFFFFFFFFFFFFFFE);
                (1, link, 0, 0)
            }
            C_BRANCH => {
                let taken = branch_taken(f3, a, b);
                redirect.send(if taken { (pc + imm_b(inst)).wrap::<u64>() } else { link });
                (0, 0, 0, 0)
            }
            C_LOAD => (2, 0, (a + imm_i(inst)).wrap::<u64>(), 0),
            C_STORE => (3, 0, (a + imm_s(inst)).wrap::<u64>(), b),
            C_OPIMM => (1, alu(f3, if f3 == 5 { alt } else { 0 }, a, imm_i(inst).wrap::<u64>()), 0, 0),
            C_OP => (1, alu(f3, alt, a, b), 0, 0),
            C_OPIMM32 => (1, alu_w_imm(f3, alt, a, imm_i(inst).wrap::<u64>()), 0, 0),
            C_OP32 => (1, alu_w(f3, alt, a, b), 0, 0),
            C_M => (1, alu_m(f3, a, b), 0, 0),
            C_M32 => (1, alu_m_w(f3, a, b), 0, 0),
            _ => (0, 0, 0, 0),
        };

        // 目的暫存器是 x0 的指令不寫回（Decode 的記分板也不會為它計數）
        let k = if (kind == 1 || kind == 2) && rd == 0 { 0 } else { kind };
        to_mem.send((k, rd, val, addr, sdata, f3));
    }
}

/// 記憶體階段：持有資料記憶體（小端、位元組定址，每字 8 位元組）。
///   對 MMIO_OUT 的 SW 不寫記憶體，而是送一個 token（低 32 位）到 io 通道。
task Mem(from_ex: in chan<(u2, u5, u64, u64, u64, u3)>,
         wb: out chan<(u5, u64)>,
         io: out chan<u32>,
         data: [u64; DWORDS]) {
    let mut dmem: mem<u64, DWORDS> = data;

    for (kind, rd, val, addr, sdata, f3) in from_ex {
        let word = addr >> 3;
        let sh = addr[2:0] * 8;

        if kind == 1 {
            wb.send((rd, val));
        } else if kind == 2 {
            let bad = (f3 == 3 && addr[2:0] != 0)
                   || ((f3 == 2 || f3 == 6) && addr[1:0] != 0)
                   || ((f3 == 1 || f3 == 5) && addr[0:0] != 0);
            assert !bad, "misaligned load";
            assert word < DWORDS, "load address out of range";
            let w = dmem[word];
            let part = w >> sh;
            let v = match f3 {
                0 => part[7:0].wrap::<i8>().wrap::<u64>(),      // LB
                1 => part[15:0].wrap::<i16>().wrap::<u64>(),    // LH
                2 => part[31:0].wrap::<i32>().wrap::<u64>(),    // LW
                3 => w,                                         // LD
                4 => part[7:0],                                 // LBU
                5 => part[15:0],                                // LHU
                _ => part[31:0],                                // LWU
            };
            wb.send((rd, v));
        } else if kind == 3 {
            if addr == MMIO_OUT {
                io.send(sdata[31:0]);
            } else {
                let bad = (f3 == 3 && addr[2:0] != 0)
                       || (f3 == 2 && addr[1:0] != 0)
                       || (f3 == 1 && addr[0:0] != 0);
                assert !bad, "misaligned store";
                assert word < DWORDS, "store address out of range";
                let m = match f3 { 0 => 0xFF, 1 => 0xFFFF, 2 => 0xFFFFFFFF, _ => 0xFFFFFFFFFFFFFFFF };
                let w = dmem[word];
                dmem[word] = (w & ~(m << sh)) | ((sdata & m) << sh);
            }
        }
    }
}

/// 頂層：把四個階段用 FIFO 接起來。
/// WBD = 寫回 FIFO 深度。太小會讓 Mem 在 Decode 來不及排空時卡住 → 死結。
task Core<const WBD: u32>(prog: [u32; IWORDS], data: [u64; DWORDS],
                          io: out chan<u32>, dump: out chan<u64>) {
    assert WBD <= 8, "WBD > 8 could overflow the 4-bit scoreboard counters";
    let (f2d_tx, f2d_rx) = chan::<(u32, u32)>(depth = 1);
    let (d2e_tx, d2e_rx) = chan::<(u32, u32, u4, u64, u64)>(depth = 1);
    let (e2m_tx, e2m_rx) = chan::<(u2, u5, u64, u64, u64, u3)>(depth = 1);
    let (wb_tx, wb_rx)   = chan::<(u5, u64)>(depth = WBD);
    let (rd_tx, rd_rx)   = chan::<u64>(depth = 1);

    spawn Fetch(prog, f2d_tx, rd_rx);
    spawn Decode(f2d_rx, d2e_tx, wb_rx, dump);
    spawn Execute(d2e_rx, e2m_tx, rd_tx);
    spawn Mem(e2m_rx, wb_tx, io, data);
}

// ════════════════════════════════════════════════════════════════════════════
//  測試用 harness：載入程式、跑到陷阱、回傳 (傾印, MMIO 輸出)
// ════════════════════════════════════════════════════════════════════════════
fn image(p: _) -> [u32; IWORDS] { concat(p, [0; IWORDS - len(p)]) }      // 不足的部分補 0（= 非法指令）
fn dimage(d: _) -> [u64; DWORDS] { concat(d, [0; DWORDS - len(d)]) }

/// 32 位元元素版資料映像：把 u32 陣列兩兩打包進 64 位元字
/// （小端：偶數索引在字的低 32 位），給「以 4 位元組為步距定址」的 32 位元視角程式用。
fn dimage32(d: _) -> [u64; DWORDS] {
    let mut out: [u64; DWORDS] = [0; DWORDS];
    for k in 0..len(d) {
        let w = out[k >> 1];
        let v = d[k].wrap::<u64>();
        out[k >> 1] = if (k & 1) == 0 { (w & 0xFFFFFFFF00000000) | v }
                      else { (w & 0xFFFFFFFF) | (v << 32) };
    }
    out
}

fn run_with(p: _, d: _) {
    // io 深度：MMIO 寫入次數 ≤ 已發射指令數 ≤ FETCH_LIMIT，
    // 且測試端會先把 dump 收完才收 io，所以 io 必須裝得下全部輸出，否則管線未到陷阱就卡死。
    let (io_tx, io_rx) = chan::<u32>(depth = FETCH_LIMIT);
    let (dump_tx, dump_rx) = chan::<u64>(depth = 40);
    spawn Core::<WB_DEPTH>(image(p), dimage(d), io_tx, dump_tx);
    let mut regs: [u64; DUMP_LEN] = [0; DUMP_LEN];
    for i in 0..DUMP_LEN { regs[i] = dump_rx.recv(); }
    let mut out = [];
    for v in io_rx { out = concat(out, [v]); }       // Mem 結束時關閉 io
    (regs, out)
}
fn run(p: _) { run_with(p, []) }

fn cause(r: _) -> u64 { r.0[D_CAUSE] }
fn trap_pc(r: _) -> u64 { r.0[D_PC] }
fn retired(r: _) -> u64 { r.0[D_RETIRED] }
fn stalls(r: _) -> u64 { r.0[D_STALLS] }
fn reg(r: _, n: u32) -> u64 { r.0[D_X + n] }
fn output(r: _) { r.1 }
