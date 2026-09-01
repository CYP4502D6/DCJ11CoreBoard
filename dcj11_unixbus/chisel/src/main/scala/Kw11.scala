package dcj11.unix22

import chisel3._
import chisel3.util._

class Kw11(cfg: BoardConfig) extends Module {
    private val tickCycles = (cfg.clockHz + 30) / 60
    private val width = log2Ceil(tickCycles + 1).max(1)
    val io = IO(new Bundle {
                    val bus = new RegisterBus
                    val eventN = Output(Bool())
                    val acknowledge = Input(Bool())
                    val tick = Output(Bool())
                })
    val counter = RegInit(0.U(width.W))
    val done = RegInit(true.B)
    val ie = RegInit(false.B)
    val tick = WireDefault(false.B)
    when(counter === (tickCycles - 1).U) {
        counter := 0.U
        tick := true.B
    }.otherwise { counter := counter + 1.U }
    val hit = io.bus.address === Pdp11.Kw11Lks.U
    val writeHit = io.bus.writeAddress === Pdp11.Kw11Lks.U
    val write = io.bus.writePulse && writeHit && io.bus.byteEnable(0)
    io.bus.hit := hit
    io.bus.dataOut := Cat(0.U(8.W), done, ie, 0.U(6.W))

    when(io.acknowledge) {
        done := false.B
    }.elsewhen(write) {
        ie := io.bus.dataIn(6)
        done := false.B
    }.elsewhen(tick) {
        done := true.B
    }
    io.eventN := !(done && ie)
    io.tick := tick
}
