package dcj11.unix22

import chisel3._
import chisel3.util._

class UartTx(clockHz: Int, baud: Int) extends Module {
    private val bitTicks = math.max(1, (clockHz + baud / 2) / baud)
    private val width = log2Ceil(bitTicks + 1).max(1)
    val io = IO(new Bundle {
                    val start = Input(Bool())
                    val data = Input(UInt(8.W))
                    val tx = Output(Bool())
                    val ready = Output(Bool())
                })
    val busy = RegInit(false.B)
    val timer = RegInit(0.U(width.W))
    val bits = RegInit("h3ff".U(10.W))
    val index = RegInit(0.U(4.W))
    io.ready := !busy
    io.tx := Mux(busy, bits(0), true.B)
    when(io.start && !busy) {
        bits := Cat(1.U(1.W), io.data, 0.U(1.W))
        timer := (bitTicks - 1).U
        index := 0.U
        busy := true.B
    }.elsewhen(busy) {
        when(timer === 0.U) {
            bits := Cat(1.U(1.W), bits(9, 1))
            timer := (bitTicks - 1).U
            when(index === 9.U) { busy := false.B }
                .otherwise { index := index + 1.U }
        }.otherwise { timer := timer - 1.U }
    }
}

class UartRx(clockHz: Int, baud: Int) extends Module {
    private val bitTicks = math.max(1, (clockHz + baud / 2) / baud)
    private val halfTicks = math.max(1, bitTicks / 2)
    private val width = log2Ceil(bitTicks + 1).max(1)
    val io = IO(new Bundle {
                    val rx = Input(Bool())
                    val data = Output(UInt(8.W))
                    val valid = Output(Bool())
                })
    val meta = RegNext(io.rx, true.B)
    val sync = RegNext(meta, true.B)
    val idle :: start :: data :: stop :: Nil = Enum(4)
    val state = RegInit(idle)
    val timer = RegInit(0.U(width.W))
    val index = RegInit(0.U(3.W))
    val byte = RegInit(0.U(8.W))

    val idleHighCount = RegInit(0.U(width.W))
    val valid = RegInit(false.B)
    io.data := byte
    io.valid := valid
    valid := false.B
    when(sync) {
        when(idleHighCount =/= (bitTicks - 1).U) {
            idleHighCount := idleHighCount + 1.U
        }
    }.otherwise {
        idleHighCount := 0.U
    }
    switch(state) {
        is(idle) {
            when(!sync && idleHighCount === (bitTicks - 1).U) {
                byte := 0.U
                timer := (halfTicks - 1).U
                state := start
            }
        }
        is(start) {
            when(timer === 0.U) {
                when(!sync) { timer := (bitTicks - 1).U; index := 0.U; state := data }
                    .otherwise { state := idle }
            }.otherwise { timer := timer - 1.U }
        }
        is(data) {
            when(timer === 0.U) {
                byte := byte.bitSet(index, sync)
                timer := (bitTicks - 1).U
                when(index === 7.U) { state := stop }
                    .otherwise { index := index + 1.U }
            }.otherwise { timer := timer - 1.U }
        }
        is(stop) {
            when(timer === 0.U) { valid := sync; state := idle }
                .otherwise { timer := timer - 1.U }
        }
    }
}
