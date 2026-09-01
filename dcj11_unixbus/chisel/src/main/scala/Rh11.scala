package dcj11.unix22

import chisel3._
import chisel3.util._

class Rh11Rp06(cfg: BoardConfig) extends Module {
    val io = IO(new Bundle {
                    val bus = new RegisterBus
                    val memory = new MemPort
                    val block = new BlockPort
                    val irq = Output(Bool())
                    val acknowledge = Input(Bool())
                })

    private def mergeBytes(old: UInt, data: UInt, enables: UInt): UInt =
        Cat(Mux(enables(1), data(15, 8), old(15, 8)), Mux(enables(0), data(7, 0), old(7, 0)))

    val wc = RegInit(0.U(16.W))
    val ba = RegInit(0.U(16.W))
    val da = RegInit(0.U(16.W))
    val cs2 = RegInit(0.U(16.W))
    val er1 = RegInit(0.U(16.W))
    val of = RegInit(0.U(16.W))
    val dc = RegInit(0.U(16.W))
    val bae = RegInit(0.U(6.W))
    val function = RegInit(0.U(5.W))
    val ie = RegInit(false.B)
    val ready = RegInit(true.B)
    val volumeValid = RegInit(false.B)
    val pending = RegInit(false.B)
    val attention = RegInit(false.B)
    val lba = RegInit(0.U(32.W))

    val Seq(idle, requestSector, readLow, readHigh, readDma, readDmaWait,
            readDrain, writeDma, writeDmaWait, waitSector, failed, writeStream,
            writeStreamRead, writeBufferLow, writeBufferHigh, writeFillZero,
            writeRequest, readDmaErrorDrain, readDmaErrorWait) = Enum(19)
    val state = RegInit(idle)
    val lowByte = RegInit(0.U(8.W))
    val wordData = RegInit(0.U(16.W))
    val sectorByte = RegInit(0.U(10.W))
    val commandWrite = RegInit(false.B)

    val partialSector = SyncReadMem(512, UInt(8.W))
    val partialSectorRead = partialSector.read(sectorByte(8, 0), state === writeStreamRead)

    val sectorBufferWriteEnable = WireDefault(false.B)
    val sectorBufferWriteAddress = WireDefault(sectorByte(8, 0))
    val sectorBufferWriteData = WireDefault(0.U(8.W))
    when(state === writeBufferLow) {
        sectorBufferWriteEnable := true.B
        sectorBufferWriteData := wordData(7, 0)
    }.elsewhen(state === writeBufferHigh) {
        sectorBufferWriteEnable := true.B
        sectorBufferWriteData := wordData(15, 8)
    }.elsewhen(state === writeFillZero) {
        sectorBufferWriteEnable := true.B
    }
    when(sectorBufferWriteEnable) {
        partialSector.write(sectorBufferWriteAddress, sectorBufferWriteData)
    }
    val commandError = er1.orR || cs2(15, 8).orR
    val specialCondition = commandError || attention
    val busy = state =/= idle
    val unitZeroSelected = cs2(2, 0) === 0.U

    val cylinderValid = dc < cfg.rpCylinders.U
    val track = da(12, 8)
    val sector = da(4, 0)
    val addressValid = cylinderValid && track < cfg.rpTracks.U && sector < cfg.rpSectors.U
    val computedLba = ((dc * cfg.rpTracks.U + track) * cfg.rpSectors.U) + sector
    val dmaAddress = Cat(bae, ba)

    val cs1Value = Cat(
            commandError || attention, commandError, 0.U(2.W), unitZeroSelected, 0.U(1.W), bae(1, 0),
            ready, ie, function, busy
        )
    val dsValue = Cat(
            attention, commandError, 0.U(1.W), io.block.initialized, 0.U(2.W),
            0.U(1.W), 1.U(1.W), ready, volumeValid, 0.U(6.W)
        )

    val base = Pdp11.Rh11Base.U(22.W)
    val wordAddress = Cat(io.bus.address(21, 1), 0.U(1.W))
    val offset = wordAddress - base
    val writeWordAddress = Cat(io.bus.writeAddress(21, 1), 0.U(1.W))
    val writeOffset = writeWordAddress - base
    val writeHit = writeWordAddress >= base &&
        writeWordAddress <= (Pdp11.Rh11Base + 0x2a).U
    io.bus.hit := wordAddress >= base && wordAddress <= (Pdp11.Rh11Base + 0x2a).U
    io.bus.dataOut := MuxLookup(offset, 0.U)(Seq(
                                                 "o00".U -> cs1Value,
                                                 "o02".U -> wc,
                                                 "o04".U -> ba,
                                                 "o06".U -> da,
                                                 "o10".U -> cs2,
                                                 "o12".U -> Mux(unitZeroSelected, dsValue, 0.U),
                                                 "o14".U -> er1,
                                                 "o16".U -> Cat(0.U(15.W), attention),
                                                 "o20".U -> 0.U,
                                                 "o22".U -> 0.U,
                                                 "o24".U -> 0.U,

                                                 "o26".U -> Mux(unitZeroSelected, "o020022".U, 0.U),
                                                 "o30".U -> Mux(unitZeroSelected, 1.U, 0.U),
                                                 "o32".U -> of,
                                                 "o34".U -> dc,
                                                 "o36".U -> dc,
                                                 "o50".U -> Cat(0.U(10.W), bae),
                                                 "o52".U -> 0.U
                                             ))

    io.memory.request.valid := false.B
    io.memory.request.bits.write := false.B
    io.memory.request.bits.address := dmaAddress
    io.memory.request.bits.data := wordData
    io.memory.request.bits.byteEnable := "b11".U
    io.block.request.valid := false.B
    io.block.request.bits.write := commandWrite && state === writeRequest
    io.block.request.bits.lba := lba
    io.block.read.ready := false.B
    io.block.write.valid := false.B
    io.block.write.bits := 0.U
    io.irq := pending || (specialCondition && ready && ie)

    def setError(er1Bits: Int = 0, cs2Bits: Int = 0): Unit = {
        er1 := er1 | er1Bits.U
        cs2 := cs2 | cs2Bits.U
        ready := true.B
        attention := true.B

        when(!ready && ie) { pending := true.B }
        state := failed
    }
    def complete(): Unit = {
        ready := true.B
        attention := false.B

        when(ie) { pending := true.B }
        state := idle
    }
    def advanceDma(): Unit = {
        wc := wc + 1.U
        val nextAddress = dmaAddress + 2.U
        ba := nextAddress(15, 0)
        bae := nextAddress(21, 16)
    }
    def advanceDisk(): Unit = {
        when(sector === (cfg.rpSectors - 1).U) {
            when(track === (cfg.rpTracks - 1).U) {
                dc := dc + 1.U
                da := 0.U
            }
                .otherwise { da := Cat(0.U(3.W), track + 1.U, 0.U(8.W)) }
        }.otherwise { da := da + 1.U }
        lba := lba + 1.U
    }
    def finishReadDmaMemoryError(): Unit = {
        when(lba >= cfg.rpImageSectors.U) {
            setError(cs2Bits = 0x0800)
        }.otherwise {
            state := Mux(sectorByte === 512.U, readDmaErrorWait, readDmaErrorDrain)
        }
    }
    def startTransfer(write: Bool): Unit = {
        when(!io.block.initialized) { setError(er1Bits = 0x4000) }
            .elsewhen(cs2(2, 0) =/= 0.U) { setError(cs2Bits = 0x1000) }
            .elsewhen(!volumeValid) { setError(er1Bits = 0x4000) }
            .elsewhen(!addressValid) { setError(er1Bits = 0x0400) }
            .elsewhen(computedLba >= cfg.rpImageSectors.U && write) { setError(er1Bits = 0x0200) }
            .otherwise {
                commandWrite := write
                lba := computedLba
                sectorByte := 0.U
                ready := false.B
                pending := false.B
                state := requestSector
            }
    }

    when(io.acknowledge) { pending := false.B; ie := false.B }


    when(io.bus.writePulse && writeHit && state === idle) {
        switch(writeOffset) {
            is("o00".U) {
                val merged = mergeBytes(cs1Value, io.bus.dataIn, io.bus.byteEnable)
                ie := merged(6)
                bae := Cat(bae(5, 2), merged(9, 8))
                function := merged(5, 1)

                when(io.bus.byteEnable(0) && io.bus.dataIn(7) && io.bus.dataIn(6)) {
                    pending := true.B
                }
                when(merged(0)) {
                    when(!unitZeroSelected) {

                        setError(cs2Bits = 0x1000)
                    }.otherwise { switch(Cat(merged(5, 1), 0.U(1.W))) {
                                     is("o04".U) {
                                         when(addressValid) { attention := true.B }
                                             .otherwise { setError(er1Bits = 0x0400) }
                                     }
                                     is("o06".U) {
                                         dc := 0.U; da := da & "hff00".U; attention := true.B
                                     }
                                     is("o10".U) { er1 := 0.U; cs2 := cs2 & "h00ff".U; attention := false.B }
                                     is("o20".U) {
                                         volumeValid := true.B
                                         dc := 0.U
                                         da := 0.U
                                         of := "o010000".U
                                         attention := true.B
                                     }
                                     is("o22".U) { volumeValid := true.B; attention := true.B }
                                     is("o30".U) {
                                         when(addressValid) { attention := true.B }
                                             .otherwise { setError(er1Bits = 0x0400) }
                                     }

                                     is("o50".U) { setError(er1Bits = 0x0001) }
                                     is("o60".U) { startTransfer(true.B) }
                                     is("o70".U) { startTransfer(false.B) }
                                 } }
                }
            }
            is("o02".U) { wc := mergeBytes(wc, io.bus.dataIn, io.bus.byteEnable) }
            is("o04".U) { ba := mergeBytes(ba, io.bus.dataIn, io.bus.byteEnable) & "hfffe".U }
            is("o06".U) { da := mergeBytes(da, io.bus.dataIn, io.bus.byteEnable) }
            is("o10".U) {
                val merged = mergeBytes(cs2, io.bus.dataIn, io.bus.byteEnable)
                when(merged(5)) {
                    cs2 := 0.U; er1 := 0.U; pending := false.B; attention := false.B
                    volumeValid := false.B; function := 0.U; ie := false.B; ready := true.B
                }.otherwise { cs2 := Cat(cs2(15, 3), merged(2, 0)) }
            }
            is("o14".U) { er1 := er1 & ~mergeBytes(0.U, io.bus.dataIn, io.bus.byteEnable) }
            is("o16".U) { attention := false.B }
            is("o32".U) { of := mergeBytes(of, io.bus.dataIn, io.bus.byteEnable) }
            is("o34".U) { dc := mergeBytes(dc, io.bus.dataIn, io.bus.byteEnable) }
            is("o50".U) { bae := mergeBytes(Cat(0.U(10.W), bae), io.bus.dataIn, io.bus.byteEnable)(5, 0) }
        }
    }

    switch(state) {
        is(idle) {}
        is(requestSector) {
            when(lba >= cfg.rpImageSectors.U) {
                when(commandWrite) {
                    setError(er1Bits = 0x0200)
                }.otherwise {
                    lowByte := 0.U
                    wordData := 0.U
                    state := readDma
                }
            }.otherwise {
                when(commandWrite) {
                    sectorByte := 0.U
                    state := writeDma
                }.otherwise {
                    io.block.request.valid := true.B
                    when(io.block.request.fire) {
                        sectorByte := 0.U
                        state := readLow
                    }
                }
            }
        }
        is(readLow) {
            io.block.read.ready := true.B
            when(io.block.read.fire) { lowByte := io.block.read.bits; sectorByte := sectorByte + 1.U; state := readHigh }
        }
        is(readHigh) {
            io.block.read.ready := true.B
            when(io.block.read.fire) {
                wordData := Cat(io.block.read.bits, lowByte)
                sectorByte := sectorByte + 1.U
                state := readDma
            }
        }
        is(readDma) {
            io.memory.request.valid := true.B
            io.memory.request.bits.write := true.B
            io.memory.request.bits.data := wordData
            when(io.memory.request.fire) { state := readDmaWait }
        }
        is(readDmaWait) {
            when(io.memory.responseValid) {
                when(io.memory.responseError) { finishReadDmaMemoryError() }
                    .otherwise {
                        val lastWord = wc === "hffff".U
                        advanceDma()
                        when(lba >= cfg.rpImageSectors.U) {
                            when(lastWord) { advanceDisk(); complete() }
                                .elsewhen(sectorByte === 510.U) { advanceDisk(); state := requestSector }
                                .otherwise { sectorByte := sectorByte + 2.U; wordData := 0.U; state := readDma }
                        }.elsewhen(lastWord) { state := readDrain }
                            .elsewhen(sectorByte === 512.U) { state := waitSector }
                            .otherwise { state := readLow }
                    }
            }
        }
        is(readDmaErrorDrain) {
            io.block.read.ready := true.B
            when(sectorByte === 512.U) { state := readDmaErrorWait }
                .elsewhen(io.block.read.fire) { sectorByte := sectorByte + 1.U }
        }
        is(readDmaErrorWait) {
            when(io.block.done) {
                when(io.block.error) { setError(er1Bits = 0x2000, cs2Bits = 0x0800) }
                    .otherwise { setError(cs2Bits = 0x0800) }
            }
        }
        is(readDrain) {
            io.block.read.ready := true.B
            when(sectorByte === 512.U) { state := waitSector }
                .elsewhen(io.block.read.fire) { sectorByte := sectorByte + 1.U }
        }
        is(writeDma) {
            io.memory.request.valid := true.B
            io.memory.request.bits.write := false.B
            when(io.memory.request.fire) { state := writeDmaWait }
        }
        is(writeDmaWait) {
            when(io.memory.responseValid) {
                when(io.memory.responseError) { setError(cs2Bits = 0x0800) }
                    .otherwise { wordData := io.memory.responseData; state := writeBufferLow }
            }
        }
        is(writeBufferLow) {
            sectorByte := sectorByte + 1.U
            state := writeBufferHigh
        }
        is(writeBufferHigh) {
            val lastWord = wc === "hffff".U
            advanceDma()
            when(lastWord && sectorByte =/= 511.U) {
                sectorByte := sectorByte + 1.U
                state := writeFillZero
            }.elsewhen(lastWord || sectorByte === 511.U) {
                sectorByte := 0.U
                state := writeRequest
            }.otherwise {
                sectorByte := sectorByte + 1.U
                state := writeDma
            }
        }
        is(writeFillZero) {
            when(sectorByte === 511.U) {
                sectorByte := 0.U
                state := writeRequest
            }.otherwise { sectorByte := sectorByte + 1.U }
        }
        is(writeRequest) {
            io.block.request.valid := true.B
            when(io.block.request.fire) {
                sectorByte := 0.U
                state := writeStreamRead
            }
        }
        is(writeStream) {
            io.block.write.valid := true.B
            io.block.write.bits := partialSectorRead
            when(io.block.write.fire) {
                when(sectorByte === 511.U) { state := waitSector }
                    .otherwise { sectorByte := sectorByte + 1.U; state := writeStreamRead }
            }
        }
        is(writeStreamRead) {
            state := writeStream
        }
        is(waitSector) {
            when(io.block.error) { setError(er1Bits = 0x2000) }
                .elsewhen(io.block.done) {
                    when(wc === 0.U) { advanceDisk(); complete() }
                        .otherwise {
                            advanceDisk()
                            sectorByte := 0.U
                            state := requestSector
                        }
                }
        }
        is(failed) { state := idle }
    }

    when(busy) { assert(ready === false.B || state === failed, "RH ready cannot assert during transfer") }
    when(io.memory.request.valid) { assert(ba(0) === 0.U, "RH DMA address must be word aligned") }
    when(io.block.request.valid && commandWrite) {
        assert(lba < cfg.rpImageSectors.U, "RH write must remain inside the real image extent")
    }
    when(state === writeFillZero) {
        assert(wc === 0.U, "RH short-sector padding may begin only after WC wraps")
        assert(sectorByte < 512.U, "RH short-sector padding must stop at the card boundary")
    }
}
