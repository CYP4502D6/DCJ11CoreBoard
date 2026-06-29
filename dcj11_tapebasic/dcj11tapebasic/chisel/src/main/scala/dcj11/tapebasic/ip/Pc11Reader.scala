package dcj11.tapebasic.ip

import chisel3._
import chisel3.util._

class Pc11Reader(
    baseAddr: BigInt = BigInt("17777550", 8),
    aliasBaseAddr: BigInt = BigInt("177550", 8)
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

                    val tapeValid = Input(Bool())
                    val tapeData = Input(UInt(8.W))
                    val tapeReady = Output(Bool())
                    val tapeDone = Input(Bool())
                    val tapeError = Input(Bool())

                    val punchValid = Output(Bool())
                    val punchData = Output(UInt(8.W))
                    val punchReady = Input(Bool())
                })

    private val prcsrAddr = (baseAddr + 0).U(22.W)
    private val prbufAddr = (baseAddr + 2).U(22.W)
    private val ppcsrAddr = (baseAddr + 4).U(22.W)
    private val ppbufAddr = (baseAddr + 6).U(22.W)
    private val prcsrAliasAddr = (aliasBaseAddr + 0).U(16.W)
    private val prbufAliasAddr = (aliasBaseAddr + 2).U(16.W)
    private val ppcsrAliasAddr = (aliasBaseAddr + 4).U(16.W)
    private val ppbufAliasAddr = (aliasBaseAddr + 6).U(16.W)
    private val busAddr16 = io.busAddr(15, 0)

    val hitCsr = (io.busAddr === prcsrAddr) || (busAddr16 === prcsrAliasAddr)
    val hitBuf = (io.busAddr === prbufAddr) || (busAddr16 === prbufAliasAddr)
    val hitPunchCsr = (io.busAddr === ppcsrAddr) || (busAddr16 === ppcsrAliasAddr)
    val hitPunchBuf = (io.busAddr === ppbufAddr) || (busAddr16 === ppbufAliasAddr)
    val hit = hitCsr || hitBuf || hitPunchCsr || hitPunchBuf

    val done = RegInit(false.B)
    val busy = RegInit(false.B)
    val intEnable = RegInit(false.B)
    val punchIntEnable = RegInit(false.B)
    val data = RegInit(0.U(8.W))
    val punchData = RegInit(0.U(8.W))
    val punchRequest = RegInit(false.B)
    val errorSeen = RegInit(false.B)
    val readerIrq = RegInit(false.B)
    val punchIrq = RegInit(false.B)
    val donePrev = RegNext(done, false.B)
    val punchReadyPrev = RegNext(io.punchReady, false.B)

    val writePunch = io.busStrobe && hitPunchBuf && io.busWrite
    val readBuf = hitBuf && io.busRead
    val doneRise = done && !donePrev
    val punchReadyRise = io.punchReady && !punchReadyPrev

    io.tapeReady := busy && !done
    io.punchValid := punchRequest
    io.punchData := punchData

    when(io.tapeValid && io.tapeReady) {
        data := io.tapeData
        done := true.B
        busy := false.B
    }

    when(io.tapeError) {
        errorSeen := true.B
        busy := false.B
    }

    when(io.busStrobe && hitCsr && io.busWrite) {
        intEnable := io.busWdata(6)
        when(io.busWdata(0)) {
            done := false.B
            busy := !io.tapeDone && !io.tapeError
            readerIrq := false.B
        }
    }

    when(readBuf) {
        done := false.B
        readerIrq := false.B
    }

    when(io.busStrobe && hitPunchCsr && io.busWrite) {
        punchIntEnable := io.busWdata(6)
    }

    when(writePunch) {
        punchData := io.busWdata(7, 0)
        when(io.punchReady) {
            punchRequest := true.B
        }
    }.elsewhen(!io.punchReady) {
        punchRequest := false.B
    }

    when(doneRise && intEnable) {
        readerIrq := true.B
    }

    when(punchReadyRise && punchIntEnable) {
        punchIrq := true.B
    }

    when(io.irqAck) {
        when(readerIrq) {
            readerIrq := false.B
        }.otherwise {
            punchIrq := false.B
        }
    }

    val csr = Cat(errorSeen, 0.U(3.W), busy, 0.U(3.W), done, intEnable, 0.U(6.W))
    val punchCsr = Cat(errorSeen, 0.U(7.W), io.punchReady, punchIntEnable, 0.U(6.W))
    io.busHit := hit
    io.busRdata :=
        Mux(hitBuf, Cat(0.U(8.W), data),
            Mux(hitPunchCsr, punchCsr,
                Mux(hitPunchBuf, Cat(0.U(8.W), punchData), csr)))
    io.irq := readerIrq || punchIrq
    io.irqVector := Mux(readerIrq, BigInt("70", 8).U(16.W),
                        Mux(punchIrq, BigInt("74", 8).U(16.W), 0.U(16.W)))
}
