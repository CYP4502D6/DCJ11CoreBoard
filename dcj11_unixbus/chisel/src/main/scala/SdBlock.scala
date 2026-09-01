package dcj11.unix22

import chisel3._
import chisel3.util._

class SdBlockDevice(cfg: BoardConfig) extends Module {
    private val initHalfTicks = math.max(1, cfg.clockHz / (cfg.sdInitHz * 2))
    private val runHalfTicks = math.max(1, cfg.clockHz / (cfg.sdRunHz * 2))
    require(runHalfTicks >= 3,
            "two-stage SD MISO sampling requires at least three CLK50 cycles per half SCK")
    private val timerWidth = log2Ceil(math.max(initHalfTicks, runHalfTicks) + 1).max(1)
    private val responseTimeout = 64
    private val tokenTimeout = 65535
    private val acmdLimit = 8192
    private val powerUpWaitCycles = math.max(1,
                                             ((cfg.clockHz.toLong * cfg.sdPowerUpDelayMs) / 1000L).toInt)
    private val retryWaitCycles = math.max(1,
                                           ((cfg.clockHz.toLong * cfg.sdRetryDelayMs) / 1000L).toInt)
    private val initWaitWidth = log2Ceil(math.max(powerUpWaitCycles, retryWaitCycles) + 1).max(1)

    private def crc16Byte(crc: UInt, data: UInt): UInt = {
        var next = crc
        for (bit <- 7 to 0 by -1) {
            val feedback = next(15) ^ data(bit)
            next = Cat(next(14, 0), 0.U(1.W)) ^ Mux(feedback, "h1021".U(16.W), 0.U(16.W))
        }
        next
    }

    private def crc7Byte(crc: UInt, data: UInt): UInt = {
        var next = crc
        for (bit <- 7 to 0 by -1) {
            val feedback = next(6) ^ data(bit)
            next = Cat(next(5, 0), 0.U(1.W)) ^ Mux(feedback, "h09".U(7.W), 0.U(7.W))
        }
        next
    }

    private def commandCrcByte(number: UInt, argument: UInt): UInt = {
        var crc = 0.U(7.W)
        crc = crc7Byte(crc, Cat("b01".U(2.W), number))
        crc = crc7Byte(crc, argument(31, 24))
        crc = crc7Byte(crc, argument(23, 16))
        crc = crc7Byte(crc, argument(15, 8))
        crc = crc7Byte(crc, argument(7, 0))
        Cat(crc, 1.U(1.W))
    }

    val io = IO(new Bundle {
                    val block = Flipped(new BlockPort)
                    val miso = Input(Bool())
                    val sck = Output(Bool())
                    val mosi = Output(Bool())
                    val csN = Output(Bool())
                    val active = Output(Bool())
                })

    val spiFast = RegInit(false.B)
    val spiBusy = RegInit(false.B)
    val spiSck = RegInit(false.B)
    val spiMosi = RegInit(true.B)
    val spiTimer = RegInit(0.U(timerWidth.W))
    val spiBit = RegInit(7.U(3.W))
    val spiTxShift = RegInit("hff".U(8.W))
    val spiRxShift = RegInit(0.U(8.W))

    val misoMeta = RegNext(io.miso, true.B)
    val misoSync = RegNext(misoMeta, true.B)
    val spiStart = WireDefault(false.B)
    val spiTx = WireDefault("hff".U(8.W))
    val spiDone = WireDefault(false.B)
    val halfTicks = Mux(spiFast, (runHalfTicks - 1).U, (initHalfTicks - 1).U)

    when(spiStart && !spiBusy) {
        spiBusy := true.B
        spiSck := false.B
        spiTimer := halfTicks
        spiBit := 7.U
        spiTxShift := spiTx
        spiMosi := spiTx(7)
        spiRxShift := 0.U
    }.elsewhen(spiBusy) {
        when(spiTimer === 0.U) {
            spiTimer := halfTicks
            when(!spiSck) {
                spiSck := true.B
                spiRxShift := Cat(spiRxShift(6, 0), misoSync)
            }.otherwise {
                spiSck := false.B
                when(spiBit === 0.U) {
                    spiBusy := false.B
                    spiMosi := true.B
                    spiDone := true.B
                }.otherwise {
                    spiBit := spiBit - 1.U
                    spiTxShift := Cat(spiTxShift(6, 0), 1.U(1.W))
                    spiMosi := spiTxShift(6)
                }
            }
        }.otherwise { spiTimer := spiTimer - 1.U }
    }

    val Seq(cIdle, cSend, cSendWait, cResponse, cResponseWait,
            cExtra, cExtraWait, cPostClock, cPostClockWait, cDone, cFailed) = Enum(11)
    val commandState = RegInit(cIdle)
    val commandStart = WireDefault(false.B)
    val commandNumber = WireDefault(0.U(6.W))
    val commandArgument = WireDefault(0.U(32.W))
    val commandExtraCount = WireDefault(0.U(3.W))
    val commandPostClock = WireDefault(false.B)
    val commandNumberReg = Reg(UInt(6.W))
    val commandArgumentReg = Reg(UInt(32.W))
    val commandCrcReg = Reg(UInt(8.W))
    val commandExtraCountReg = Reg(UInt(3.W))
    val commandPostClockReg = RegInit(false.B)
    val commandIndex = RegInit(0.U(3.W))
    val commandTries = RegInit(0.U(7.W))
    val commandExtraIndex = RegInit(0.U(3.W))
    val commandResponse = RegInit("hff".U(8.W))
    val commandExtra = RegInit(VecInit(Seq.fill(4)(0.U(8.W))))
    val commandDone = WireDefault(false.B)
    val commandFailed = WireDefault(false.B)
    val commandByte = Wire(UInt(8.W))
    commandByte := MuxLookup(commandIndex, commandCrcReg)(Seq(
                                                              0.U -> Cat("b01".U(2.W), commandNumberReg),
                                                              1.U -> commandArgumentReg(31, 24),
                                                              2.U -> commandArgumentReg(23, 16),
                                                              3.U -> commandArgumentReg(15, 8),
                                                              4.U -> commandArgumentReg(7, 0)
                                                          ))

    when(commandStart && commandState === cIdle) {
        commandNumberReg := commandNumber
        commandArgumentReg := commandArgument
        commandCrcReg := commandCrcByte(commandNumber, commandArgument)
        commandExtraCountReg := commandExtraCount
        commandPostClockReg := commandPostClock
        commandIndex := 0.U
        commandTries := 0.U
        commandExtraIndex := 0.U
        commandState := cSend
    }.otherwise {
        switch(commandState) {
            is(cSend) {
                when(!spiBusy) { spiStart := true.B; spiTx := commandByte; commandState := cSendWait }
            }
            is(cSendWait) {
                when(spiDone) {
                    when(commandIndex === 5.U) { commandState := cResponse }
                        .otherwise { commandIndex := commandIndex + 1.U; commandState := cSend }
                }
            }
            is(cResponse) {
                when(!spiBusy) { spiStart := true.B; spiTx := "hff".U; commandState := cResponseWait }
            }
            is(cResponseWait) {
                when(spiDone) {
                    when(!spiRxShift(7)) {
                        commandResponse := spiRxShift
                        when(commandExtraCountReg === 0.U) {
                            commandState := Mux(commandPostClockReg, cPostClock, cDone)
                        }
                            .otherwise { commandExtraIndex := 0.U; commandState := cExtra }
                    }.elsewhen(commandTries === (responseTimeout - 1).U) { commandState := cFailed }
                        .otherwise { commandTries := commandTries + 1.U; commandState := cResponse }
                }
            }
            is(cExtra) {
                when(!spiBusy) { spiStart := true.B; spiTx := "hff".U; commandState := cExtraWait }
            }
            is(cExtraWait) {
                when(spiDone) {
                    commandExtra(commandExtraIndex(1, 0)) := spiRxShift
                    when(commandExtraIndex === commandExtraCountReg - 1.U) {
                        commandState := Mux(commandPostClockReg, cPostClock, cDone)
                    }
                        .otherwise { commandExtraIndex := commandExtraIndex + 1.U; commandState := cExtra }
                }
            }
            is(cPostClock) {
                when(!spiBusy) {
                    spiStart := true.B
                    spiTx := "hff".U
                    commandState := cPostClockWait
                }
            }
            is(cPostClockWait) { when(spiDone) { commandState := cDone } }
            is(cDone) { commandDone := true.B; commandState := cIdle }
            is(cFailed) { commandFailed := true.B; commandState := cIdle }
        }
    }

    val sdStates = Enum(42)
    val sPowerWait = sdStates(0)
    val sTrain = sdStates(1)
    val sCmd0 = sdStates(2)
    val sCmd0Wait = sdStates(3)
    val sCmd8 = sdStates(4)
    val sCmd8Wait = sdStates(5)
    val sCmd55 = sdStates(6)
    val sCmd55Wait = sdStates(7)
    val sAcmd41 = sdStates(8)
    val sAcmd41Wait = sdStates(9)
    val sCmd58 = sdStates(10)
    val sCmd58Wait = sdStates(11)
    val sCmd16 = sdStates(12)
    val sCmd16Wait = sdStates(13)
    val sIdle = sdStates(14)
    val sReadCommand = sdStates(15)
    val sReadCommandWait = sdStates(16)
    val sReadToken = sdStates(17)
    val sReadTokenWait = sdStates(18)
    val sReadByte = sdStates(19)
    val sReadByteWait = sdStates(20)
    val sReadHold = sdStates(21)
    val sReadCrc = sdStates(22)
    val sReadCrcWait = sdStates(23)
    val sWriteCommand = sdStates(24)
    val sWriteCommandWait = sdStates(25)
    val sWriteToken = sdStates(26)
    val sWriteTokenWait = sdStates(27)
    val sWriteByte = sdStates(28)
    val sWriteByteWait = sdStates(29)
    val sWriteCrc = sdStates(30)
    val sWriteCrcWait = sdStates(31)
    val sWriteResponse = sdStates(32)
    val sWriteResponseWait = sdStates(33)
    val sWriteBusy = sdStates(34)
    val sWriteBusyWait = sdStates(35)
    val sFinish = sdStates(36)
    val sError = sdStates(37)
    val sPostTransaction = sdStates(38)
    val sPostTransactionWait = sdStates(39)
    val sCmd59 = sdStates(40)
    val sCmd59Wait = sdStates(41)
    val state = RegInit(sPowerWait)
    val csN = RegInit(true.B)
    val initialized = RegInit(false.B)
    val failed = RegInit(false.B)
    val sdhc = RegInit(true.B)
    val version2 = RegInit(true.B)
    val trainCount = RegInit(0.U(4.W))
    val acmdCount = RegInit(0.U(14.W))
    val tokenCount = RegInit(0.U(16.W))
    val byteIndex = RegInit(0.U(10.W))
    val crcIndex = RegInit(0.U(1.W))
    val readCrc = RegInit(0.U(16.W))
    val readCrcHigh = RegInit(0.U(8.W))
    val writeCrc = RegInit(0.U(16.W))
    val requestWrite = RegInit(false.B)
    val requestLba = RegInit(0.U(32.W))
    val initWait = RegInit(0.U(initWaitWidth.W))
    val readValid = RegInit(false.B)
    val readData = RegInit(0.U(8.W))
    val done = RegInit(false.B)
    val operationError = RegInit(false.B)

    def launch(number: Int, argument: UInt, extra: Int, next: UInt,
               postClock: Boolean = false): Unit = {
        when(commandState === cIdle) {
            commandNumber := number.U
            commandArgument := argument
            commandExtraCount := extra.U
            commandPostClock := postClock.B
            commandStart := true.B
            state := next
        }
    }
    def cardArgument(lba: UInt): UInt = Mux(sdhc, lba, lba << 9)
    def failInitialization(): Unit = {
        failed := true.B
        initialized := false.B
        operationError := true.B
        csN := true.B
        initWait := 0.U
        state := sError
    }
    def failOperation(): Unit = {
        operationError := true.B
        state := sFinish
    }

    io.block.request.ready := state === sIdle && initialized
    io.block.read.valid := readValid
    io.block.read.bits := readData
    io.block.write.ready := state === sWriteByte && !spiBusy
    io.block.done := done
    io.block.error := failed || operationError
    io.block.initialized := initialized
    io.sck := spiSck
    io.mosi := spiMosi
    io.csN := csN
    io.active := state =/= sIdle && state =/= sError
    done := false.B

    switch(state) {
        is(sPowerWait) {
            csN := true.B
            when(initWait === (powerUpWaitCycles - 1).U) {
                initWait := 0.U
                trainCount := 0.U
                state := sTrain
            }.otherwise { initWait := initWait + 1.U }
        }
        is(sTrain) {
            csN := true.B
            when(!spiBusy) { spiStart := true.B; spiTx := "hff".U }
            when(spiDone) {
                when(trainCount === 9.U) { trainCount := 0.U; csN := false.B; state := sCmd0 }
                    .otherwise { trainCount := trainCount + 1.U }
            }
        }
        is(sCmd0) { launch(0, 0.U, 0, sCmd0Wait, postClock = true) }
        is(sCmd0Wait) {
            when(commandFailed || (commandDone && commandResponse =/= 1.U)) { failInitialization() }
                .elsewhen(commandDone) { state := sCmd8 }
        }
        is(sCmd8) { launch(8, "h000001aa".U, 4, sCmd8Wait, postClock = true) }
        is(sCmd8Wait) {
            when(commandFailed) { failInitialization() }
                .elsewhen(commandDone && commandResponse === 1.U) {
                    when(commandExtra(0) =/= 0.U || commandExtra(1) =/= 0.U ||
                             commandExtra(2) =/= 1.U || commandExtra(3) =/= "haa".U) {
                        failInitialization()
                    }.otherwise {
                        version2 := true.B
                        acmdCount := 0.U
                        state := sCmd59
                    }
                }.elsewhen(commandDone && commandResponse === 5.U) {
                    version2 := false.B
                    sdhc := false.B
                    acmdCount := 0.U
                    state := sCmd59
                }.elsewhen(commandDone) { failInitialization() }
        }
        is(sCmd59) { launch(59, 1.U, 0, sCmd59Wait, postClock = true) }
        is(sCmd59Wait) {
            when(commandFailed || (commandDone && commandResponse =/= 1.U)) {
                failInitialization()
            }.elsewhen(commandDone) { state := sCmd55 }
        }
        is(sCmd55) { launch(55, 0.U, 0, sCmd55Wait, postClock = true) }
        is(sCmd55Wait) {
            when(commandFailed || (commandDone && commandResponse =/= 0.U && commandResponse =/= 1.U)) {
                failInitialization()
            }.elsewhen(commandDone) { state := sAcmd41 }
        }
        is(sAcmd41) {
            launch(41, Mux(version2, "h40000000".U, 0.U), 0, sAcmd41Wait,
                   postClock = true)
        }
        is(sAcmd41Wait) {
            when(commandFailed || (commandDone && commandResponse =/= 0.U && commandResponse =/= 1.U)) {
                failInitialization()
            }.elsewhen(commandDone && commandResponse === 0.U) {
                state := Mux(version2, sCmd58, sCmd16)
            }.elsewhen(commandDone && acmdCount === (acmdLimit - 1).U) { failInitialization() }
                .elsewhen(commandDone) { acmdCount := acmdCount + 1.U; state := sCmd55 }
        }
        is(sCmd58) { launch(58, 0.U, 4, sCmd58Wait, postClock = true) }
        is(sCmd58Wait) {
            when(commandFailed || (commandDone && commandResponse =/= 0.U)) { failInitialization() }
                .elsewhen(commandDone) {
                    sdhc := commandExtra(0)(6)
                    when(commandExtra(0)(6)) { initialized := true.B; spiFast := true.B; state := sIdle }
                        .otherwise { state := sCmd16 }
                }
        }
        is(sCmd16) { launch(16, 512.U, 0, sCmd16Wait, postClock = true) }
        is(sCmd16Wait) {
            when(commandFailed || (commandDone && commandResponse =/= 0.U)) { failInitialization() }
                .elsewhen(commandDone) { initialized := true.B; spiFast := true.B; state := sIdle }
        }
        is(sIdle) {
            csN := true.B
            operationError := false.B
            readValid := false.B
            when(io.block.request.fire) {
                requestWrite := io.block.request.bits.write
                requestLba := io.block.request.bits.lba
                byteIndex := 0.U
                tokenCount := 0.U
                readCrc := 0.U
                writeCrc := 0.U
                csN := false.B
                state := Mux(io.block.request.bits.write, sWriteCommand, sReadCommand)
            }
        }
        is(sReadCommand) { launch(17, cardArgument(requestLba), 0, sReadCommandWait) }
        is(sReadCommandWait) {
            when(commandFailed || (commandDone && commandResponse =/= 0.U)) { failOperation() }
                .elsewhen(commandDone) { tokenCount := 0.U; state := sReadToken }
        }
        is(sReadToken) { when(!spiBusy) { spiStart := true.B; spiTx := "hff".U; state := sReadTokenWait } }
        is(sReadTokenWait) {
            when(spiDone && spiRxShift === "hfe".U) {
                byteIndex := 0.U
                readCrc := 0.U
                state := sReadByte
            }
                .elsewhen(spiDone && tokenCount === (tokenTimeout - 1).U) { failOperation() }
                .elsewhen(spiDone) { tokenCount := tokenCount + 1.U; state := sReadToken }
        }
        is(sReadByte) { when(!spiBusy) { spiStart := true.B; spiTx := "hff".U; state := sReadByteWait } }
        is(sReadByteWait) {
            when(spiDone) {
                readData := spiRxShift
                readCrc := crc16Byte(readCrc, spiRxShift)
                readValid := true.B
                state := sReadHold
            }
        }
        is(sReadHold) {
            when(io.block.read.fire) {
                readValid := false.B
                when(byteIndex === 511.U) { crcIndex := 0.U; state := sReadCrc }
                    .otherwise { byteIndex := byteIndex + 1.U; state := sReadByte }
            }
        }
        is(sReadCrc) { when(!spiBusy) { spiStart := true.B; spiTx := "hff".U; state := sReadCrcWait } }
        is(sReadCrcWait) {
            when(spiDone) {
                when(crcIndex === 0.U) {
                    readCrcHigh := spiRxShift
                    crcIndex := 1.U
                    state := sReadCrc
                }.otherwise {
                    when(Cat(readCrcHigh, spiRxShift) =/= readCrc) {
                        operationError := true.B
                    }
                    state := sPostTransaction
                }
            }
        }
        is(sWriteCommand) { launch(24, cardArgument(requestLba), 0, sWriteCommandWait) }
        is(sWriteCommandWait) {
            when(commandFailed || (commandDone && commandResponse =/= 0.U)) { failOperation() }
                .elsewhen(commandDone) { state := sWriteToken }
        }
        is(sWriteToken) { when(!spiBusy) { spiStart := true.B; spiTx := "hfe".U; state := sWriteTokenWait } }
        is(sWriteTokenWait) {
            when(spiDone) { byteIndex := 0.U; writeCrc := 0.U; state := sWriteByte }
        }
        is(sWriteByte) {
            when(io.block.write.fire) {
                spiStart := true.B
                spiTx := io.block.write.bits
                writeCrc := crc16Byte(writeCrc, io.block.write.bits)
                state := sWriteByteWait
            }
        }
        is(sWriteByteWait) {
            when(spiDone) {
                when(byteIndex === 511.U) { crcIndex := 0.U; state := sWriteCrc }
                    .otherwise { byteIndex := byteIndex + 1.U; state := sWriteByte }
            }
        }
        is(sWriteCrc) {
            when(!spiBusy) {
                spiStart := true.B
                spiTx := Mux(crcIndex === 0.U, writeCrc(15, 8), writeCrc(7, 0))
                state := sWriteCrcWait
            }
        }
        is(sWriteCrcWait) {
            when(spiDone) {
                when(crcIndex === 1.U) { state := sWriteResponse }
                    .otherwise { crcIndex := crcIndex + 1.U; state := sWriteCrc }
            }
        }
        is(sWriteResponse) { when(!spiBusy) { spiStart := true.B; spiTx := "hff".U; state := sWriteResponseWait } }
        is(sWriteResponseWait) {
            when(spiDone && spiRxShift(4, 0) =/= 5.U) { failOperation() }
                .elsewhen(spiDone) { tokenCount := 0.U; state := sWriteBusy }
        }
        is(sWriteBusy) { when(!spiBusy) { spiStart := true.B; spiTx := "hff".U; state := sWriteBusyWait } }
        is(sWriteBusyWait) {
            when(spiDone && spiRxShift === "hff".U) { state := sPostTransaction }
                .elsewhen(spiDone && tokenCount === (tokenTimeout - 1).U) { failOperation() }
                .elsewhen(spiDone) { tokenCount := tokenCount + 1.U; state := sWriteBusy }
        }

        is(sPostTransaction) {
            when(!spiBusy) { spiStart := true.B; spiTx := "hff".U; state := sPostTransactionWait }
        }
        is(sPostTransactionWait) { when(spiDone) { state := sFinish } }
        is(sFinish) { csN := true.B; done := true.B; state := sIdle }
        is(sError) {
            csN := true.B
            when(initWait === (retryWaitCycles - 1).U) {
                initWait := 0.U
                trainCount := 0.U
                acmdCount := 0.U
                tokenCount := 0.U
                failed := false.B
                operationError := false.B
                sdhc := true.B
                version2 := true.B
                spiFast := false.B
                state := sTrain
            }.otherwise { initWait := initWait + 1.U }
        }
    }

    when(io.block.request.fire) {
        assert(io.block.request.bits.lba < cfg.rpNominalSectors.U, "RP06 LBA outside advertised geometry")
    }
    when(readValid) { assert(state === sReadHold, "read byte may only persist in hold state") }
    val unused = requestWrite
}
