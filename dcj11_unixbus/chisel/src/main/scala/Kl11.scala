package dcj11.unix22

import chisel3._
import chisel3.util._

class Kl11(cfg: BoardConfig) extends Module {
    val io = IO(new Bundle {
                    val bus = new RegisterBus
                    val uartRx = Input(Bool())
                    val uartTx = Output(Bool())
                    val irq = Output(Bool())
                    val vector = Output(UInt(16.W))
                    val acknowledge = Input(Bool())
                    val acknowledgeVector = Input(UInt(16.W))
                })
    val rx = Module(new UartRx(cfg.clockHz, cfg.uartBaud))
    val tx = Module(new UartTx(cfg.clockHz, cfg.uartBaud))
    rx.io.rx := io.uartRx

    val rxDone = RegInit(false.B)
    val rxData = RegInit(0.U(8.W))
    val rxIe = RegInit(false.B)
    val txIe = RegInit(false.B)
    val rxPending = RegInit(false.B)
    val txPending = RegInit(false.B)
    val txStart = WireDefault(false.B)
    tx.io.start := txStart

    if (cfg.uartTxMaskSoftwareParity) {
        tx.io.data := Cat(0.U(1.W), io.bus.dataIn(6, 0))
    } else {
        tx.io.data := io.bus.dataIn(7, 0)
    }
    io.uartTx := tx.io.tx

    val rcsr = Pdp11.Kl11Base.U(22.W)
    val rbuf = (Pdp11.Kl11Base + 2).U(22.W)
    val xcsr = (Pdp11.Kl11Base + 4).U(22.W)
    val xbuf = (Pdp11.Kl11Base + 6).U(22.W)
    val hitRcsr = io.bus.address === rcsr
    val hitRbuf = io.bus.address === rbuf
    val hitXcsr = io.bus.address === xcsr
    val hitXbuf = io.bus.address === xbuf
    val readHitRbuf = io.bus.readAddress === rbuf
    val writeHitRcsr = io.bus.writeAddress === rcsr
    val writeHitXcsr = io.bus.writeAddress === xcsr
    val writeHitXbuf = io.bus.writeAddress === xbuf
    io.bus.hit := hitRcsr || hitRbuf || hitXcsr || hitXbuf
    io.bus.dataOut := MuxCase(0.U, Seq(
                                  hitRcsr -> Cat(0.U(8.W), rxDone, rxIe, 0.U(6.W)),
                                  hitRbuf -> Cat(0.U(8.W), rxData),
                                  hitXcsr -> Cat(0.U(8.W), tx.io.ready, txIe, 0.U(6.W))
                              ))

    when(io.acknowledge) {
        when(io.acknowledgeVector === Pdp11.KlRxVector.U) {
            rxPending := false.B
        }.elsewhen(io.acknowledgeVector === Pdp11.KlTxVector.U) {
            txPending := false.B
        }
    }
    when(rx.io.valid) {
        rxDone := true.B
        rxData := rx.io.data
        when(rxIe) { rxPending := true.B }
    }
    when(io.bus.readPulse && readHitRbuf) { rxDone := false.B; rxPending := false.B }
    when(io.bus.writePulse && writeHitRcsr && io.bus.byteEnable(0)) {
        rxIe := io.bus.dataIn(6)
        when(!io.bus.dataIn(6)) { rxPending := false.B }
    }
    when(io.bus.writePulse && writeHitXcsr && io.bus.byteEnable(0)) {
        txIe := io.bus.dataIn(6)
        when(!io.bus.dataIn(6)) { txPending := false.B }
        when(io.bus.dataIn(6) && tx.io.ready) { txPending := true.B }
    }
    when(io.bus.writePulse && writeHitXbuf && io.bus.byteEnable(0) && tx.io.ready) {
        txStart := true.B
        txPending := false.B
    }
    val txReadyPrevious = RegNext(tx.io.ready, true.B)
    when(tx.io.ready && !txReadyPrevious && txIe) { txPending := true.B }
    io.irq := rxPending || txPending
    io.vector := Mux(rxPending, Pdp11.KlRxVector.U, Pdp11.KlTxVector.U)
}
