package dcj11.tapebasic.ip
import chisel3._
import chisel3.util._

class Kl11Console(
    clkHz: Int,
    baud: Int,
    baseAddr: BigInt = BigInt("17777560", 8),
    aliasBaseAddr: BigInt = BigInt("177560", 8),
    txDepth: Int = 64
) extends Module {
    val io = IO(new Bundle {
                    val busStrobe = Input(Bool())
                    val busRead = Input(Bool())
                    val busWrite = Input(Bool())
                    val busAddr = Input(UInt(22.W))
                    val busWdata = Input(UInt(16.W))
                    val busHit = Output(Bool())
                    val busRdata = Output(UInt(16.W))
                    val irq = Output(Bool())
                    val irqAck = Input(Bool())
                    val irqVector = Output(UInt(16.W))
                    val uartRx = Input(Bool())
                    val txReady = Input(Bool())
                    val txStart = Output(Bool())
                    val txData = Output(UInt(8.W))
                })

    private val rcsrAddr = (baseAddr + 0).U(22.W)
    private val rbufAddr = (baseAddr + 2).U(22.W)
    private val xcsrAddr = (baseAddr + 4).U(22.W)
    private val xbufAddr = (baseAddr + 6).U(22.W)
    private val rcsrAliasAddr = (aliasBaseAddr + 0).U(16.W)
    private val rbufAliasAddr = (aliasBaseAddr + 2).U(16.W)
    private val xcsrAliasAddr = (aliasBaseAddr + 4).U(16.W)
    private val xbufAliasAddr = (aliasBaseAddr + 6).U(16.W)
    private val busAddr16 = io.busAddr(15, 0)

    val rx = Module(new UartRx(clkHz, baud))
    rx.io.rx := io.uartRx

    val rxReady = RegInit(false.B)
    val rxData = RegInit(0.U(8.W))
    val rxIntEnable = RegInit(false.B)
    val txIntEnable = RegInit(false.B)
    val rxIrq = RegInit(false.B)
    val txIrq = RegInit(false.B)

    val txQueue = Module(new Queue(UInt(8.W), txDepth))
    txQueue.io.enq.valid := false.B
    txQueue.io.enq.bits := io.busWdata(7, 0)
    txQueue.io.deq.ready := io.txReady

    val txVisibleReady = !txQueue.io.deq.valid && io.txReady
    val txVisibleReadyPrev = RegNext(txVisibleReady, false.B)
    val txVisibleReadyRise = txVisibleReady && !txVisibleReadyPrev
    io.txStart := txQueue.io.deq.valid && io.txReady
    io.txData := txQueue.io.deq.bits

    when(rx.io.valid) {
        rxReady := true.B
        rxData := rx.io.data
        when(rxIntEnable) {
            rxIrq := true.B
        }
    }

    val hitRcsr = (io.busAddr === rcsrAddr) || (busAddr16 === rcsrAliasAddr)
    val hitRbuf = (io.busAddr === rbufAddr) || (busAddr16 === rbufAliasAddr)
    val hitXcsr = (io.busAddr === xcsrAddr) || (busAddr16 === xcsrAliasAddr)
    val hitXbuf = (io.busAddr === xbufAddr) || (busAddr16 === xbufAliasAddr)
    val hit = hitRcsr || hitRbuf || hitXcsr || hitXbuf

    val rcsr = Cat(0.U(8.W), rxReady, rxIntEnable, 0.U(6.W))
    val rbuf = Cat(0.U(8.W), rxData)
    val xcsr = Cat(0.U(8.W), txVisibleReady, txIntEnable, 0.U(6.W))

    io.busHit := hit
    io.busRdata := MuxCase(0.U(16.W), Seq(
                               hitRcsr -> rcsr,
                               hitRbuf -> rbuf,
                               hitXcsr -> xcsr,
                               hitXbuf -> 0.U(16.W)
                           ))
    io.irq := rxIrq || txIrq
    io.irqVector := Mux(rxIrq, BigInt("60", 8).U(16.W),
                        Mux(txIrq, BigInt("64", 8).U(16.W), 0.U(16.W)))

    when(txVisibleReadyRise && txIntEnable) {
        txIrq := true.B
    }

    when(io.busStrobe && hit && io.busWrite) {
        when(hitRcsr) {
            rxIntEnable := io.busWdata(6)
            when(!io.busWdata(6)) {
                rxIrq := false.B
            }
        }
        when(hitXcsr) {
            txIntEnable := io.busWdata(6)
            when(!io.busWdata(6)) {
                txIrq := false.B
            }
        }
        when(hitXbuf && txQueue.io.enq.ready) {
            txQueue.io.enq.valid := true.B
            txIrq := false.B
        }
    }

    when(io.busStrobe && hitRbuf && io.busRead) {
        rxReady := false.B
        rxIrq := false.B
    }

    when(io.irqAck) {
        when(rxIrq) {
            rxIrq := false.B
        }.otherwise {
            txIrq := false.B
        }
    }
}
