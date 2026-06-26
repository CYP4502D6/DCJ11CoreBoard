package dcj11.task7.ip

import chisel3._
import chisel3.util._

class Kl11Lite(
  clkHz: Int,
  baud: Int,
  baseAddr: BigInt = BigInt("17777560", 8),
  txFifoDepth: Int = 64
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
    val uartRx = Input(Bool())
    val txReady = Input(Bool())
    val txStart = Output(Bool())
    val txData = Output(UInt(8.W))
  })

  private val rcsrAddr = (baseAddr + 0).U(22.W)
  private val rbufAddr = (baseAddr + 2).U(22.W)
  private val xcsrAddr = (baseAddr + 4).U(22.W)
  private val xbufAddr = (baseAddr + 6).U(22.W)

  val rx = Module(new UartRx(clkHz, baud))
  rx.io.rx := io.uartRx

  val rxReady = RegInit(false.B)
  val rxData = RegInit(0.U(8.W))
  val rxIntEnable = RegInit(false.B)
  val txIntEnable = RegInit(false.B)
  val txQueue = Module(new Queue(UInt(8.W), txFifoDepth))
  val txVisibleReady = !txQueue.io.deq.valid && io.txReady

  io.txStart := false.B
  io.txData := txQueue.io.deq.bits

  txQueue.io.enq.valid := false.B
  txQueue.io.enq.bits := io.busWdata(7, 0)
  txQueue.io.deq.ready := io.txReady

  when(rx.io.valid) {
    rxReady := true.B
    rxData := rx.io.data
  }

  val hitRcsr = io.busAddr === rcsrAddr
  val hitRbuf = io.busAddr === rbufAddr
  val hitXcsr = io.busAddr === xcsrAddr
  val hitXbuf = io.busAddr === xbufAddr
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
  io.irq := (rxIntEnable && rxReady) || (txIntEnable && txVisibleReady)
  io.txStart := txQueue.io.deq.valid && io.txReady

  when(io.busStrobe && hit && io.busWrite) {
    when(hitRcsr) {
      rxIntEnable := io.busWdata(6)
    }
    when(hitXcsr) {
      txIntEnable := io.busWdata(6)
    }
    when(hitXbuf && txQueue.io.enq.ready) {
      txQueue.io.enq.valid := true.B
    }
  }

  when(io.busStrobe && hitRbuf && io.busRead) {
    rxReady := false.B
  }
}
