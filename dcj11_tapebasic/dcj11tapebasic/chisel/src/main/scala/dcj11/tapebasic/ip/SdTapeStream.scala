package dcj11.tapebasic.ip

import chisel3._
import chisel3.util._

class SdTapeStream(
    clkHz: Int = 50000000,
    spiInitHz: Int = 400000,
    spiRunHz: Int = 4000000,
    bootStartLba: Int = 1,
    bootBytes: Int = 10405,
    userMetaLba: Int = 22,
    userDataLba: Int = 23,
    saveIdleMs: Int = 1000,
    userRewindIdleMs: Int = 2000,
    acmd41MaxTries: Int = 8192,
    cmdResponseTimeoutBytes: Int = 64,
    dataTokenTimeoutBytes: Int = 65535
) extends Module {
    private val initHalfTicks = math.max(1, clkHz / (spiInitHz * 2))
    private val runHalfTicks = math.max(1, clkHz / (spiRunHz * 2))
    private val saveIdleCycles = math.max(1L, clkHz.toLong * saveIdleMs.toLong / 1000L)
    private val spiTimerWidth = log2Ceil(math.max(initHalfTicks, runHalfTicks) + 1).max(1)
    private val timeoutWidth = log2Ceil(math.max(cmdResponseTimeoutBytes, dataTokenTimeoutBytes) + 1).max(1)
    private val acmdTriesWidth = log2Ceil(acmd41MaxTries + 1).max(1)
    private val idleWidth = log2Ceil(saveIdleCycles + 1).max(1)
    private val userRewindIdleCycles = math.max(1L, clkHz.toLong * userRewindIdleMs.toLong / 1000L)
    private val userRewindIdleWidth = log2Ceil(userRewindIdleCycles + 1).max(1)

    val io = IO(new Bundle {
                    val sdMiso = Input(Bool())
                    val sdSck = Output(Bool())
                    val sdMosi = Output(Bool())
                    val sdCsN = Output(Bool())

                    val sessionReset = Input(Bool())
                    val forceUserMode = Input(Bool())
                    val flushUserTape = Input(Bool())

                    val outValid = Output(Bool())
                    val outReady = Input(Bool())
                    val outData = Output(UInt(8.W))

                    val punchValid = Input(Bool())
                    val punchData = Input(UInt(8.W))
                    val punchReady = Output(Bool())

                    val initialized = Output(Bool())
                    val active = Output(Bool())
                    val done = Output(Bool())
                    val error = Output(Bool())
                })

    val spiFast = RegInit(false.B)
    val csNReg = RegInit(true.B)
    val spiBusy = RegInit(false.B)
    val spiSckReg = RegInit(false.B)
    val spiMosiReg = RegInit(true.B)
    val spiTimer = RegInit(0.U(spiTimerWidth.W))
    val spiBitIndex = RegInit(7.U(3.W))
    val spiTxTail = RegInit(0.U(7.W))
    val spiRxShift = RegInit(0.U(8.W))
    val spiRxByte = RegInit(0.U(8.W))
    val spiDone = WireDefault(false.B)
    val spiStart = WireDefault(false.B)
    val spiTxByte = WireDefault("hff".U(8.W))
    val selectedHalfTicks =
        Mux(spiFast, (runHalfTicks - 1).U(spiTimerWidth.W), (initHalfTicks - 1).U(spiTimerWidth.W))

    when(spiStart && !spiBusy) {
        spiBusy := true.B
        spiSckReg := false.B
        spiMosiReg := spiTxByte(7)
        spiTimer := selectedHalfTicks
        spiBitIndex := 7.U
        spiTxTail := spiTxByte(6, 0)
        spiRxShift := 0.U
    }.elsewhen(spiBusy) {
        when(spiTimer === 0.U) {
            spiTimer := selectedHalfTicks
            when(!spiSckReg) {
                spiSckReg := true.B
                spiRxShift := Cat(spiRxShift(6, 0), io.sdMiso)
            }.otherwise {
                spiSckReg := false.B
                when(spiBitIndex === 0.U) {
                    spiBusy := false.B
                    spiMosiReg := true.B
                    spiRxByte := spiRxShift
                    spiDone := true.B
                }.otherwise {
                    spiBitIndex := spiBitIndex - 1.U
                    spiMosiReg := spiTxTail(6)
                    spiTxTail := Cat(spiTxTail(5, 0), 0.U(1.W))
                }
            }
        }.otherwise {
            spiTimer := spiTimer - 1.U
        }
    }

    io.sdSck := spiSckReg
    io.sdMosi := spiMosiReg
    io.sdCsN := csNReg

    private val cmdStates = Enum(9)
    val cmdIdle = cmdStates(0)
    val cmdSendStart = cmdStates(1)
    val cmdSendWait = cmdStates(2)
    val cmdRespStart = cmdStates(3)
    val cmdRespWait = cmdStates(4)
    val cmdExtraStart = cmdStates(5)
    val cmdExtraWait = cmdStates(6)
    val cmdDoneState = cmdStates(7)
    val cmdErrorState = cmdStates(8)
    val cmdState = RegInit(cmdIdle)
    val cmdStart = WireDefault(false.B)
    val cmdNumber = WireDefault(0.U(6.W))
    val cmdArg = WireDefault(0.U(32.W))
    val cmdCrc = WireDefault("hff".U(8.W))
    val cmdExtraCount = WireDefault(0.U(3.W))
    val cmdDonePulse = WireDefault(false.B)
    val cmdErrorPulse = WireDefault(false.B)
    val cmdNumberReg = RegInit(0.U(6.W))
    val cmdArgReg = RegInit(0.U(32.W))
    val cmdCrcReg = RegInit("hff".U(8.W))
    val cmdExtraCountReg = RegInit(0.U(3.W))
    val cmdByteIndex = RegInit(0.U(3.W))
    val cmdResponseTries = RegInit(0.U(timeoutWidth.W))
    val cmdExtraIndex = RegInit(0.U(3.W))
    val cmdResponse = RegInit("hff".U(8.W))
    val cmdExtra = RegInit(VecInit(Seq.fill(4)(0.U(8.W))))

    val cmdByte = WireDefault("hff".U(8.W))
    switch(cmdByteIndex) {
        is(0.U) { cmdByte := Cat("b01".U(2.W), cmdNumberReg) }
        is(1.U) { cmdByte := cmdArgReg(31, 24) }
        is(2.U) { cmdByte := cmdArgReg(23, 16) }
        is(3.U) { cmdByte := cmdArgReg(15, 8) }
        is(4.U) { cmdByte := cmdArgReg(7, 0) }
        is(5.U) { cmdByte := cmdCrcReg }
    }

    when(cmdStart && cmdState === cmdIdle) {
        cmdNumberReg := cmdNumber
        cmdArgReg := cmdArg
        cmdCrcReg := cmdCrc
        cmdExtraCountReg := cmdExtraCount
        cmdByteIndex := 0.U
        cmdResponseTries := 0.U
        cmdExtraIndex := 0.U
        cmdState := cmdSendStart
    }.otherwise {
        switch(cmdState) {
            is(cmdSendStart) {
                when(!spiBusy) {
                    spiStart := true.B
                    spiTxByte := cmdByte
                    cmdState := cmdSendWait
                }
            }
            is(cmdSendWait) {
                when(spiDone) {
                    when(cmdByteIndex === 5.U) {
                        cmdState := cmdRespStart
                    }.otherwise {
                        cmdByteIndex := cmdByteIndex + 1.U
                        cmdState := cmdSendStart
                    }
                }
            }
            is(cmdRespStart) {
                when(!spiBusy) {
                    spiStart := true.B
                    spiTxByte := "hff".U
                    cmdState := cmdRespWait
                }
            }
            is(cmdRespWait) {
                when(spiDone) {
                    when(!spiRxByte(7)) {
                        cmdResponse := spiRxByte
                        when(cmdExtraCountReg === 0.U) {
                            cmdState := cmdDoneState
                        }.otherwise {
                            cmdExtraIndex := 0.U
                            cmdState := cmdExtraStart
                        }
                    }.elsewhen(cmdResponseTries === (cmdResponseTimeoutBytes - 1).U) {
                        cmdState := cmdErrorState
                    }.otherwise {
                        cmdResponseTries := cmdResponseTries + 1.U
                        cmdState := cmdRespStart
                    }
                }
            }
            is(cmdExtraStart) {
                when(!spiBusy) {
                    spiStart := true.B
                    spiTxByte := "hff".U
                    cmdState := cmdExtraWait
                }
            }
            is(cmdExtraWait) {
                when(spiDone) {
                    cmdExtra(cmdExtraIndex(1, 0)) := spiRxByte
                    when(cmdExtraIndex === cmdExtraCountReg - 1.U) {
                        cmdState := cmdDoneState
                    }.otherwise {
                        cmdExtraIndex := cmdExtraIndex + 1.U
                        cmdState := cmdExtraStart
                    }
                }
            }
            is(cmdDoneState) {
                cmdDonePulse := true.B
                cmdState := cmdIdle
            }
            is(cmdErrorState) {
                cmdErrorPulse := true.B
                cmdState := cmdIdle
            }
        }
    }

    val blockMem = SyncReadMem(512, UInt(8.W))
    blockMem.suggestName("sd_block_buffer")
    val blockReadAddr = WireDefault(0.U(9.W))
    val blockReadEn = WireDefault(false.B)
    val blockReadData = blockMem.read(blockReadAddr, blockReadEn)
    val blockWriteAddr = WireDefault(0.U(9.W))
    val blockWriteData = WireDefault(0.U(8.W))
    val blockWriteEn = WireDefault(false.B)
    when(blockWriteEn) {
        blockMem.write(blockWriteAddr, blockWriteData)
    }

    val blockIndex = RegInit(0.U(10.W))
    val serveIndex = RegInit(0.U(10.W))
    val servedByteReg = RegInit(0.U(8.W))
    val writeDataReg = RegInit(0.U(8.W))
    val readLba = RegInit(bootStartLba.U(32.W))
    val bootServed = RegInit(0.U(32.W))
    val userServed = RegInit(0.U(32.W))
    val readSourceBoot = RegInit(true.B)
    val userValid = RegInit(false.B)
    val userByteLength = RegInit(0.U(32.W))
    val userSequence = RegInit(0.U(32.W))
    val userEofQueued = RegInit(false.B)
    val metaReadIndex = RegInit(0.U(4.W))
    val metaValidByte = RegInit(false.B)
    val metaLength = RegInit(0.U(32.W))
    val metaSequence = RegInit(0.U(32.W))

    val writeActive = RegInit(false.B)
    val writeLba = RegInit(userDataLba.U(32.W))
    val writeIndex = RegInit(0.U(10.W))
    val writeByteLength = RegInit(0.U(32.W))
    val writeTrimmedByteLength = RegInit(0.U(32.W))
    val writeValidBytes = RegInit(0.U(10.W))
    val writeMetadataMode = RegInit(false.B)
    val writeFinalizeAfterData = RegInit(false.B)
    val saveIdleCounter = RegInit(0.U(idleWidth.W))
    val forceUserPending = RegInit(false.B)
    val flushPending = RegInit(false.B)
    val userReadIdleCounter = RegInit(0.U(userRewindIdleWidth.W))
    val userReadSinceRewind = RegInit(false.B)

    val acmdTries = RegInit(0.U(acmdTriesWidth.W))
    val tokenCount = RegInit(0.U(timeoutWidth.W))
    val crcIndex = RegInit(0.U(1.W))
    val trainCount = RegInit(0.U(4.W))
    val initializedReg = RegInit(false.B)
    val errorReg = RegInit(false.B)
    val doneReg = RegInit(false.B)
    val blockReady = RegInit(false.B)
    val blockAddressMode = RegInit(true.B)
    val readingMetadata = RegInit(false.B)

    private val streamStates = Enum(46)
    val sBoot = streamStates(0)
    val sClockTrainStart = streamStates(1)
    val sClockTrainWait = streamStates(2)
    val sCmd0Start = streamStates(3)
    val sCmd0Wait = streamStates(4)
    val sCmd8Start = streamStates(5)
    val sCmd8Wait = streamStates(6)
    val sCmd55Start = streamStates(7)
    val sCmd55Wait = streamStates(8)
    val sAcmd41Start = streamStates(9)
    val sAcmd41Wait = streamStates(10)
    val sCmd58Start = streamStates(11)
    val sCmd58Wait = streamStates(12)
    val sCmd16Start = streamStates(13)
    val sCmd16Wait = streamStates(14)
    val sNeedReadBlock = streamStates(15)
    val sNeedUserMeta = streamStates(16)
    val sCmd17Start = streamStates(17)
    val sCmd17Wait = streamStates(18)
    val sTokenStart = streamStates(19)
    val sTokenWait = streamStates(20)
    val sReadByteStart = streamStates(21)
    val sReadByteWait = streamStates(22)
    val sCrcStart = streamStates(23)
    val sCrcWait = streamStates(24)
    val sMetaReadWait = streamStates(25)
    val sParseMeta = streamStates(26)
    val sServeLoadWait = streamStates(27)
    val sServe = streamStates(28)
    val sUserDone = streamStates(29)
    val sCmd24Start = streamStates(30)
    val sCmd24Wait = streamStates(31)
    val sWriteTokenStart = streamStates(32)
    val sWriteTokenWait = streamStates(33)
    val sWriteByteLoad = streamStates(34)
    val sWriteByteStart = streamStates(35)
    val sWriteByteWait = streamStates(36)
    val sWriteCrcStart = streamStates(37)
    val sWriteCrcWait = streamStates(38)
    val sWriteRespStart = streamStates(39)
    val sWriteRespWait = streamStates(40)
    val sWriteBusyStart = streamStates(41)
    val sWriteBusyWait = streamStates(42)
    val sWriteDone = streamStates(43)
    val sError = streamStates(44)
    val sPunchHold = streamStates(45)
    val state = RegInit(sBoot)

    def fail(): Unit = {
        errorReg := true.B
        csNReg := true.B
        blockReady := false.B
        state := sError
    }

    def currentLbaArg(lba: UInt): UInt = {
        Mux(blockAddressMode, lba, lba << 9)
    }

    def startCommand(number: Int, arg: UInt, crc: Int, extraBytes: Int, waitState: UInt): Unit = {
        when(cmdState === cmdIdle) {
            cmdNumber := number.U
            cmdArg := arg
            cmdCrc := crc.U(8.W)
            cmdExtraCount := extraBytes.U
            cmdStart := true.B
            state := waitState
        }
    }

    def resetSession(): Unit = {
        readSourceBoot := !io.forceUserMode
        bootServed := 0.U
        userServed := 0.U
        readLba := Mux(io.forceUserMode, userMetaLba.U, bootStartLba.U)
        doneReg := false.B
        blockReady := false.B
        readingMetadata := io.forceUserMode
        userEofQueued := false.B
        writeActive := false.B
        writeLba := userDataLba.U
        writeIndex := 0.U
        writeByteLength := 0.U
        writeTrimmedByteLength := 0.U
        writeValidBytes := 0.U
        writeMetadataMode := false.B
        writeFinalizeAfterData := false.B
        saveIdleCounter := 0.U
        forceUserPending := false.B
        flushPending := false.B
        userReadIdleCounter := 0.U
        userReadSinceRewind := false.B
    }

    def rewindUserReader(): Unit = {
        readSourceBoot := false.B
        userServed := 0.U
        readLba := userMetaLba.U
        doneReg := false.B
        blockReady := false.B
        readingMetadata := false.B
        userEofQueued := false.B
        userReadIdleCounter := 0.U
        userReadSinceRewind := false.B
        state := sNeedUserMeta
    }

    def metadataReadAddr(index: UInt): UInt = {
        MuxLookup(index, 12.U(9.W))(Seq(
                                        0.U -> 12.U(9.W),
                                        1.U -> 16.U(9.W),
                                        2.U -> 17.U(9.W),
                                        3.U -> 18.U(9.W),
                                        4.U -> 19.U(9.W),
                                        5.U -> 20.U(9.W),
                                        6.U -> 21.U(9.W),
                                        7.U -> 22.U(9.W),
                                        8.U -> 23.U(9.W)
                                    ))
    }

    def captureMetadataByte(index: UInt, data: UInt): Unit = {
        switch(index) {
            is(0.U) { metaValidByte := data === 1.U }
            is(1.U) { metaLength := Cat(0.U(24.W), data) }
            is(2.U) { metaLength := Cat(0.U(16.W), data, metaLength(7, 0)) }
            is(3.U) { metaLength := Cat(0.U(8.W), data, metaLength(15, 0)) }
            is(4.U) { metaLength := Cat(data, metaLength(23, 0)) }
            is(5.U) { metaSequence := Cat(0.U(24.W), data) }
            is(6.U) { metaSequence := Cat(0.U(16.W), data, metaSequence(7, 0)) }
            is(7.U) { metaSequence := Cat(0.U(8.W), data, metaSequence(15, 0)) }
            is(8.U) { metaSequence := Cat(data, metaSequence(23, 0)) }
        }
    }

    val nextUserSequence = userSequence + 1.U

    def metadataByte(index: UInt): UInt = {
        val byte = WireDefault(0.U(8.W))
        switch(index) {
            is(0.U) { byte := "h44".U } // D
            is(1.U) { byte := "h43".U } // C
            is(2.U) { byte := "h4a".U } // J
            is(3.U) { byte := "h50".U } // P
            is(4.U) { byte := "h54".U } // T
            is(5.U) { byte := "h41".U } // A
            is(6.U) { byte := "h50".U } // P
            is(7.U) { byte := "h45".U } // E
            is(8.U) { byte := 1.U }
            is(12.U) { byte := 1.U }
            is(16.U) { byte := writeTrimmedByteLength(7, 0) }
            is(17.U) { byte := writeTrimmedByteLength(15, 8) }
            is(18.U) { byte := writeTrimmedByteLength(23, 16) }
            is(19.U) { byte := writeTrimmedByteLength(31, 24) }
            is(20.U) { byte := nextUserSequence(7, 0) }
            is(21.U) { byte := nextUserSequence(15, 8) }
            is(22.U) { byte := nextUserSequence(23, 16) }
            is(23.U) { byte := nextUserSequence(31, 24) }
        }
        byte
    }

    val sessionResetPrev = RegNext(io.sessionReset, false.B)
    val sessionResetPulse = io.sessionReset && !sessionResetPrev

    val readTotalBytes =
        Mux(readSourceBoot, bootBytes.U(32.W), userByteLength)
    val readServed = Mux(readSourceBoot, bootServed, userServed)
    val bytesRemainingTotal =
        Mux(readTotalBytes > readServed, readTotalBytes - readServed, 0.U)
    val byteRemainingInBlock = 512.U(10.W) - serveIndex
    val writeDataByte = Mux(writeMetadataMode, metadataByte(blockIndex), writeDataReg)
    val punchIdleState = (state === sServe) || (state === sUserDone)
    val canPunch = initializedReg && !errorReg && punchIdleState
    val acceptPunch = canPunch && io.punchValid
    val servedByte = servedByteReg
    val userNulTerminator =
        !readSourceBoot && !userEofQueued && userServed =/= 0.U && servedByte === 0.U

    io.outValid := blockReady && !errorReg && state === sServe
    io.outData := Mux(userNulTerminator, "h1a".U, servedByte)
    io.punchReady := canPunch
    io.initialized := initializedReg
    io.active := state =/= sUserDone && !errorReg
    io.done := doneReg
    io.error := errorReg

    when(sessionResetPulse) {
        resetSession()
        when(initializedReg) {
            state := Mux(io.forceUserMode, sNeedUserMeta, sNeedReadBlock)
        }
    }.otherwise {
        when(io.forceUserMode && readSourceBoot && initializedReg) {
            forceUserPending := true.B
        }
        when(io.flushUserTape && writeActive) {
            flushPending := true.B
        }

        switch(state) {
            is(sBoot) {
                csNReg := true.B
                spiFast := false.B
                errorReg := false.B
                doneReg := false.B
                initializedReg := false.B
                blockReady := false.B
                trainCount := 0.U
                resetSession()
                state := sClockTrainStart
            }
            is(sClockTrainStart) {
                csNReg := true.B
                when(!spiBusy) {
                    spiStart := true.B
                    spiTxByte := "hff".U
                    state := sClockTrainWait
                }
            }
            is(sClockTrainWait) {
                when(spiDone) {
                    when(trainCount === 9.U) {
                        trainCount := 0.U
                        csNReg := false.B
                        state := sCmd0Start
                    }.otherwise {
                        trainCount := trainCount + 1.U
                        state := sClockTrainStart
                    }
                }
            }
            is(sCmd0Start) { startCommand(0, 0.U, 0x95, 0, sCmd0Wait) }
            is(sCmd0Wait) {
                when(cmdErrorPulse || (cmdDonePulse && cmdResponse =/= "h01".U)) { fail() }
                    .elsewhen(cmdDonePulse) { state := sCmd8Start }
            }
            is(sCmd8Start) { startCommand(8, "h000001aa".U, 0x87, 4, sCmd8Wait) }
            is(sCmd8Wait) {
                when(cmdErrorPulse || (cmdDonePulse && (
                                           cmdResponse =/= "h01".U || cmdExtra(0) =/= 0.U || cmdExtra(1) =/= 0.U ||
                                               cmdExtra(2) =/= 1.U || cmdExtra(3) =/= "haa".U))) { fail() }
                    .elsewhen(cmdDonePulse) {
                        acmdTries := 0.U
                        state := sCmd55Start
                    }
            }
            is(sCmd55Start) { startCommand(55, 0.U, 0x65, 0, sCmd55Wait) }
            is(sCmd55Wait) {
                when(cmdErrorPulse || (cmdDonePulse && cmdResponse =/= "h01".U && cmdResponse =/= 0.U)) { fail() }
                    .elsewhen(cmdDonePulse) { state := sAcmd41Start }
            }
            is(sAcmd41Start) { startCommand(41, "h40000000".U, 0x77, 0, sAcmd41Wait) }
            is(sAcmd41Wait) {
                when(cmdErrorPulse || (cmdDonePulse && cmdResponse =/= "h00".U && cmdResponse =/= "h01".U)) { fail() }
                    .elsewhen(cmdDonePulse && cmdResponse === "h00".U) { state := sCmd58Start }
                    .elsewhen(cmdDonePulse) {
                        when(acmdTries === (acmd41MaxTries - 1).U) { fail() }
                            .otherwise {
                                acmdTries := acmdTries + 1.U
                                state := sCmd55Start
                            }
                    }
            }
            is(sCmd58Start) { startCommand(58, 0.U, 0xfd, 4, sCmd58Wait) }
            is(sCmd58Wait) {
                when(cmdErrorPulse || (cmdDonePulse && cmdResponse =/= "h00".U)) { fail() }
                    .elsewhen(cmdDonePulse) {
                        blockAddressMode := cmdExtra(0)(6)
                        when(cmdExtra(0)(6)) {
                            spiFast := true.B
                            initializedReg := true.B
                            resetSession()
                            state := sNeedReadBlock
                        }.otherwise {
                            state := sCmd16Start
                        }
                    }
            }
            is(sCmd16Start) { startCommand(16, 512.U, 0xff, 0, sCmd16Wait) }
            is(sCmd16Wait) {
                when(cmdErrorPulse || (cmdDonePulse && cmdResponse =/= 0.U)) { fail() }
                    .elsewhen(cmdDonePulse) {
                        spiFast := true.B
                        initializedReg := true.B
                        resetSession()
                        state := sNeedReadBlock
                    }
            }
            is(sNeedReadBlock) {
                when(forceUserPending && readSourceBoot && !writeActive) {
                    readSourceBoot := false.B
                    readLba := userMetaLba.U
                    userServed := 0.U
                    userEofQueued := false.B
                    doneReg := false.B
                    blockReady := false.B
                    readingMetadata := false.B
                    forceUserPending := false.B
                    userReadIdleCounter := 0.U
                    userReadSinceRewind := false.B
                    state := sNeedUserMeta
                }.elsewhen(readTotalBytes === 0.U || bytesRemainingTotal === 0.U) {
                    when(readSourceBoot) {
                        readSourceBoot := false.B
                        userServed := 0.U
                        userEofQueued := false.B
                        doneReg := false.B
                        userReadIdleCounter := 0.U
                        userReadSinceRewind := false.B
                        state := sNeedUserMeta
                    }.otherwise {
                        doneReg := true.B
                        state := sUserDone
                    }
                }.otherwise {
                    readingMetadata := false.B
                    csNReg := false.B
                    state := sCmd17Start
                }
            }
            is(sNeedUserMeta) {
                readLba := userMetaLba.U
                readingMetadata := true.B
                doneReg := false.B
                csNReg := false.B
                state := sCmd17Start
            }
            is(sCmd17Start) { startCommand(17, currentLbaArg(readLba), 0xff, 0, sCmd17Wait) }
            is(sCmd17Wait) {
                when(cmdErrorPulse || (cmdDonePulse && cmdResponse =/= 0.U)) { fail() }
                    .elsewhen(cmdDonePulse) {
                        tokenCount := 0.U
                        state := sTokenStart
                    }
            }
            is(sTokenStart) {
                when(!spiBusy) {
                    spiStart := true.B
                    spiTxByte := "hff".U
                    state := sTokenWait
                }
            }
            is(sTokenWait) {
                when(spiDone) {
                    when(spiRxByte === "hfe".U) {
                        blockIndex := 0.U
                        state := sReadByteStart
                    }.elsewhen(spiRxByte =/= "hff".U || tokenCount === (dataTokenTimeoutBytes - 1).U) {
                        fail()
                    }.otherwise {
                        tokenCount := tokenCount + 1.U
                        state := sTokenStart
                    }
                }
            }
            is(sReadByteStart) {
                when(!spiBusy) {
                    spiStart := true.B
                    spiTxByte := "hff".U
                    state := sReadByteWait
                }
            }
            is(sReadByteWait) {
                when(spiDone) {
                    blockWriteAddr := blockIndex(8, 0)
                    blockWriteData := spiRxByte
                    blockWriteEn := true.B
                    when(blockIndex === 511.U) {
                        crcIndex := 0.U
                        state := sCrcStart
                    }.otherwise {
                        blockIndex := blockIndex + 1.U
                        state := sReadByteStart
                    }
                }
            }
            is(sCrcStart) {
                when(!spiBusy) {
                    spiStart := true.B
                    spiTxByte := "hff".U
                    state := sCrcWait
                }
            }
            is(sCrcWait) {
                when(spiDone) {
                    when(crcIndex === 1.U) {
                        csNReg := true.B
                        when(readingMetadata) {
                            metaReadIndex := 0.U
                            metaValidByte := false.B
                            metaLength := 0.U
                            metaSequence := 0.U
                            blockReadAddr := metadataReadAddr(0.U)
                            blockReadEn := true.B
                            state := sMetaReadWait
                        }.otherwise {
                            serveIndex := 0.U
                            blockReady := false.B
                            blockReadAddr := 0.U
                            blockReadEn := true.B
                            state := sServeLoadWait
                        }
                    }.otherwise {
                        crcIndex := crcIndex + 1.U
                        state := sCrcStart
                    }
                }
            }
            is(sMetaReadWait) {
                captureMetadataByte(metaReadIndex, blockReadData)
                when(metaReadIndex === 8.U) {
                    state := sParseMeta
                }.otherwise {
                    val nextMetaReadIndex = metaReadIndex + 1.U
                    metaReadIndex := nextMetaReadIndex
                    blockReadAddr := metadataReadAddr(nextMetaReadIndex)
                    blockReadEn := true.B
                }
            }
            is(sParseMeta) {
                userValid := metaValidByte
                userByteLength := metaLength
                userSequence := metaSequence
                userServed := 0.U
                userEofQueued := false.B
                userReadIdleCounter := 0.U
                userReadSinceRewind := false.B
                readLba := userDataLba.U
                readingMetadata := false.B
                when(metaValidByte && metaLength =/= 0.U) {
                    doneReg := false.B
                    state := sNeedReadBlock
                }.otherwise {
                    servedByteReg := "h1a".U
                    userByteLength := 1.U
                    userEofQueued := true.B
                    serveIndex := 0.U
                    blockReady := true.B
                    doneReg := false.B
                    state := sServe
                }
            }
            is(sServeLoadWait) {
                servedByteReg := blockReadData
                blockReady := true.B
                state := sServe
            }
            is(sServe) {
                when(forceUserPending && readSourceBoot && !writeActive) {
                    readSourceBoot := false.B
                    readLba := userMetaLba.U
                    userServed := 0.U
                    userEofQueued := false.B
                    doneReg := false.B
                    blockReady := false.B
                    readingMetadata := false.B
                    forceUserPending := false.B
                    userReadIdleCounter := 0.U
                    userReadSinceRewind := false.B
                    state := sNeedUserMeta
                }.elsewhen(acceptPunch) {
                    blockReady := false.B
                    doneReg := false.B
                    readSourceBoot := false.B
                    userServed := 0.U
                    userEofQueued := false.B
                    userReadIdleCounter := 0.U
                    userReadSinceRewind := false.B
                    readLba := userDataLba.U
                    when(!writeActive) {
                        writeActive := true.B
                        writeLba := userDataLba.U
                        writeIndex := 0.U
                        writeByteLength := 0.U
                        writeTrimmedByteLength := 0.U
                    }
                    blockWriteAddr := writeIndex(8, 0)
                    blockWriteData := io.punchData
                    blockWriteEn := true.B
                    writeByteLength := writeByteLength + 1.U
                    when(io.punchData =/= 0.U) {
                        writeTrimmedByteLength := writeByteLength + 1.U
                    }
                    saveIdleCounter := 0.U
                    flushPending := false.B
                    when(writeIndex === 511.U) {
                        writeIndex := 0.U
                        writeValidBytes := 512.U
                        writeMetadataMode := false.B
                        writeFinalizeAfterData := false.B
                        state := sCmd24Start
                    }.otherwise {
                        writeIndex := writeIndex + 1.U
                        state := sPunchHold
                    }
                }.elsewhen(io.outValid && io.outReady) {
                    userReadIdleCounter := 0.U
                    when(readSourceBoot) {
                        bootServed := bootServed + 1.U
                        when(bytesRemainingTotal === 1.U) {
                            blockReady := false.B
                            readSourceBoot := false.B
                            userServed := 0.U
                            userEofQueued := false.B
                            userReadSinceRewind := false.B
                            doneReg := false.B
                            state := sNeedUserMeta
                        }.elsewhen(byteRemainingInBlock === 1.U) {
                            blockReady := false.B
                            readLba := readLba + 1.U
                            state := sNeedReadBlock
                        }.otherwise {
                            val nextServeIndex = serveIndex + 1.U
                            serveIndex := nextServeIndex
                            blockReady := false.B
                            blockReadAddr := nextServeIndex(8, 0)
                            blockReadEn := true.B
                            state := sServeLoadWait
                        }
                    }.otherwise {
                        userReadSinceRewind := true.B
                        when(userEofQueued) {
                            servedByteReg := "h1a".U
                            serveIndex := 0.U
                            blockReady := true.B
                            userEofQueued := true.B
                            doneReg := false.B
                            state := sServe
                        }.elsewhen(userNulTerminator) {
                            servedByteReg := "h1a".U
                            serveIndex := 0.U
                            blockReady := true.B
                            userEofQueued := true.B
                            doneReg := false.B
                            state := sServe
                        }.otherwise {
                            userServed := userServed + 1.U
                            when(bytesRemainingTotal === 1.U) {
                                servedByteReg := "h1a".U
                                serveIndex := 0.U
                                blockReady := true.B
                                userEofQueued := true.B
                                doneReg := false.B
                                state := sServe
                            }.elsewhen(byteRemainingInBlock === 1.U) {
                                blockReady := false.B
                                readLba := readLba + 1.U
                                state := sNeedReadBlock
                            }.otherwise {
                                val nextServeIndex = serveIndex + 1.U
                                serveIndex := nextServeIndex
                                blockReady := false.B
                                blockReadAddr := nextServeIndex(8, 0)
                                blockReadEn := true.B
                                state := sServeLoadWait
                            }
                        }
                    }
                }.elsewhen(writeActive) {
                    when(flushPending || saveIdleCounter === (saveIdleCycles - 1).U) {
                        saveIdleCounter := 0.U
                        flushPending := false.B
                        when(writeIndex === 0.U) {
                            writeMetadataMode := true.B
                            writeFinalizeAfterData := false.B
                            state := sCmd24Start
                        }.otherwise {
                            writeValidBytes := writeIndex
                            writeMetadataMode := false.B
                            writeFinalizeAfterData := true.B
                            state := sCmd24Start
                        }
                    }.otherwise {
                        saveIdleCounter := saveIdleCounter + 1.U
                    }
                }.elsewhen(!readSourceBoot && userReadSinceRewind) {
                    when(userReadIdleCounter === (userRewindIdleCycles - 1).U) {
                        rewindUserReader()
                    }.otherwise {
                        userReadIdleCounter := userReadIdleCounter + 1.U
                    }
                }
            }
            is(sUserDone) {
                when(acceptPunch) {
                    doneReg := false.B
                    readSourceBoot := false.B
                    userServed := 0.U
                    userEofQueued := false.B
                    userReadIdleCounter := 0.U
                    userReadSinceRewind := false.B
                    readLba := userDataLba.U
                    when(!writeActive) {
                        writeActive := true.B
                        writeLba := userDataLba.U
                        writeIndex := 0.U
                        writeByteLength := 0.U
                        writeTrimmedByteLength := 0.U
                    }
                    blockWriteAddr := writeIndex(8, 0)
                    blockWriteData := io.punchData
                    blockWriteEn := true.B
                    writeByteLength := writeByteLength + 1.U
                    when(io.punchData =/= 0.U) {
                        writeTrimmedByteLength := writeByteLength + 1.U
                    }
                    saveIdleCounter := 0.U
                    flushPending := false.B
                    when(writeIndex === 511.U) {
                        writeIndex := 0.U
                        writeValidBytes := 512.U
                        writeMetadataMode := false.B
                        writeFinalizeAfterData := false.B
                        state := sCmd24Start
                    }.otherwise {
                        writeIndex := writeIndex + 1.U
                        state := sPunchHold
                    }
                }.elsewhen(writeActive) {
                    when(flushPending || saveIdleCounter === (saveIdleCycles - 1).U) {
                        saveIdleCounter := 0.U
                        flushPending := false.B
                        when(writeIndex === 0.U) {
                            writeMetadataMode := true.B
                            writeFinalizeAfterData := false.B
                            state := sCmd24Start
                        }.otherwise {
                            writeValidBytes := writeIndex
                            writeMetadataMode := false.B
                            writeFinalizeAfterData := true.B
                            state := sCmd24Start
                        }
                    }.otherwise {
                        saveIdleCounter := saveIdleCounter + 1.U
                    }
                }.elsewhen(userReadSinceRewind) {
                    when(userReadIdleCounter === (userRewindIdleCycles - 1).U) {
                        rewindUserReader()
                    }.otherwise {
                        userReadIdleCounter := userReadIdleCounter + 1.U
                    }
                }
            }
            is(sPunchHold) {
                state := sUserDone
            }
            is(sCmd24Start) {
                csNReg := false.B
                blockIndex := 0.U
                crcIndex := 0.U
                tokenCount := 0.U
                val targetLba = Mux(writeMetadataMode, userMetaLba.U(32.W), writeLba)
                startCommand(24, currentLbaArg(targetLba), 0xff, 0, sCmd24Wait)
            }
            is(sCmd24Wait) {
                when(cmdErrorPulse || (cmdDonePulse && cmdResponse =/= 0.U)) { fail() }
                    .elsewhen(cmdDonePulse) { state := sWriteTokenStart }
            }
            is(sWriteTokenStart) {
                when(!spiBusy) {
                    spiStart := true.B
                    spiTxByte := "hfe".U
                    state := sWriteTokenWait
                }
            }
            is(sWriteTokenWait) {
                when(spiDone) {
                    blockIndex := 0.U
                    when(writeMetadataMode) {
                        state := sWriteByteStart
                    }.otherwise {
                        blockReadAddr := 0.U
                        blockReadEn := true.B
                        state := sWriteByteLoad
                    }
                }
            }
            is(sWriteByteLoad) {
                writeDataReg := Mux(blockIndex < writeValidBytes, blockReadData, 0.U(8.W))
                state := sWriteByteStart
            }
            is(sWriteByteStart) {
                when(!spiBusy) {
                    spiStart := true.B
                    spiTxByte := writeDataByte
                    state := sWriteByteWait
                }
            }
            is(sWriteByteWait) {
                when(spiDone) {
                    when(blockIndex === 511.U) {
                        crcIndex := 0.U
                        state := sWriteCrcStart
                    }.otherwise {
                        val nextBlockIndex = blockIndex + 1.U
                        blockIndex := nextBlockIndex
                        when(writeMetadataMode) {
                            state := sWriteByteStart
                        }.otherwise {
                            blockReadAddr := nextBlockIndex(8, 0)
                            blockReadEn := true.B
                            state := sWriteByteLoad
                        }
                    }
                }
            }
            is(sWriteCrcStart) {
                when(!spiBusy) {
                    spiStart := true.B
                    spiTxByte := "hff".U
                    state := sWriteCrcWait
                }
            }
            is(sWriteCrcWait) {
                when(spiDone) {
                    when(crcIndex === 1.U) {
                        tokenCount := 0.U
                        state := sWriteRespStart
                    }.otherwise {
                        crcIndex := crcIndex + 1.U
                        state := sWriteCrcStart
                    }
                }
            }
            is(sWriteRespStart) {
                when(!spiBusy) {
                    spiStart := true.B
                    spiTxByte := "hff".U
                    state := sWriteRespWait
                }
            }
            is(sWriteRespWait) {
                when(spiDone) {
                    when(spiRxByte(4, 0) === "h05".U) {
                        tokenCount := 0.U
                        state := sWriteBusyStart
                    }.elsewhen(spiRxByte === "hff".U && tokenCount =/= (dataTokenTimeoutBytes - 1).U) {
                        tokenCount := tokenCount + 1.U
                        state := sWriteRespStart
                    }.otherwise {
                        fail()
                    }
                }
            }
            is(sWriteBusyStart) {
                when(!spiBusy) {
                    spiStart := true.B
                    spiTxByte := "hff".U
                    state := sWriteBusyWait
                }
            }
            is(sWriteBusyWait) {
                when(spiDone) {
                    when(spiRxByte =/= 0.U) {
                        state := sWriteDone
                    }.elsewhen(tokenCount === (dataTokenTimeoutBytes - 1).U) {
                        fail()
                    }.otherwise {
                        tokenCount := tokenCount + 1.U
                        state := sWriteBusyStart
                    }
                }
            }
            is(sWriteDone) {
                csNReg := true.B
                when(writeMetadataMode) {
                    userSequence := nextUserSequence
                    userValid := true.B
                    userByteLength := writeTrimmedByteLength
                    writeActive := false.B
                    writeIndex := 0.U
                    writeMetadataMode := false.B
                    writeFinalizeAfterData := false.B
                    readSourceBoot := false.B
                    userServed := 0.U
                    userEofQueued := false.B
                    userReadIdleCounter := 0.U
                    userReadSinceRewind := false.B
                    readLba := userDataLba.U
                    when(writeTrimmedByteLength === 0.U) {
                        doneReg := true.B
                        state := sUserDone
                    }.otherwise {
                        doneReg := false.B
                        state := sNeedReadBlock
                    }
                }.otherwise {
                    writeLba := writeLba + 1.U
                    writeIndex := 0.U
                    when(writeFinalizeAfterData) {
                        writeMetadataMode := true.B
                        writeFinalizeAfterData := false.B
                        state := sCmd24Start
                    }.otherwise {
                        state := sUserDone
                    }
                }
            }
            is(sError) {
                csNReg := true.B
            }
        }
    }
}
