package dcj11.unix22

import chisel3._
import chisel3.util._

private object AwTxnKind {
    val globalControl = 0.U(3.W)
    val globalCurrent = 1.U(3.W)
    val channelCurrent = 2.U(3.W)
    val addressBrightness = 3.U(3.W)
    val dataBrightness = 4.U(3.W)
    val update = 5.U(3.W)
}

private class Aw21024I2cBurstWriter(
    clkHz: Int,
    i2cHz: Int,
    onBrightness: Int,
    offBrightness: Int,
    globalCurrent: Int,
    channelCurrent: Int
) extends Module {
    private val halfDivider = math.max(1, clkHz / math.max(1, i2cHz * 2))
    private val tickWidth = log2Ceil(halfDivider + 1).max(1)

    val io = IO(new Bundle {
                    val start = Input(Bool())
                    val deviceAddress = Input(UInt(7.W))
                    val registerAddress = Input(UInt(8.W))
                    val length = Input(UInt(5.W))
                    val kind = Input(UInt(3.W))
                    val addressValue = Input(UInt(22.W))
                    val dataValue = Input(UInt(16.W))
                    val sclDriveLow = Output(Bool())
                    val sdaDriveLow = Output(Bool())
                    val busy = Output(Bool())
                    val done = Output(Bool())
                })

    private val writerStates = Enum(14)
    private val idle = writerStates(0)
    private val start1 = writerStates(1)
    private val start2 = writerStates(2)
    private val start3 = writerStates(3)
    private val loadByte = writerStates(4)
    private val bitSetup = writerStates(5)
    private val bitHigh = writerStates(6)
    private val bitLow = writerStates(7)
    private val ackSetup = writerStates(8)
    private val ackHigh = writerStates(9)
    private val ackLow = writerStates(10)
    private val stop1 = writerStates(11)
    private val stop2 = writerStates(12)
    private val stop3 = writerStates(13)

    val state = RegInit(idle)
    val tickCount = RegInit(0.U(tickWidth.W))
    val sclDriveLow = RegInit(false.B)
    val sdaDriveLow = RegInit(false.B)
    val deviceAddress = RegInit(0.U(7.W))
    val registerAddress = RegInit(0.U(8.W))
    val length = RegInit(1.U(5.W))
    val kind = RegInit(AwTxnKind.update)
    val addressValue = RegInit(0.U(22.W))
    val dataValue = RegInit(0.U(16.W))
    val currentByte = RegInit(0.U(8.W))
    val byteIndex = RegInit(0.U(6.W))
    val bitIndex = RegInit(7.U(3.W))
    val done = RegInit(false.B)

    def payload(kind: UInt, index: UInt, address: UInt, data: UInt): UInt = {
        val addressOn = index < 22.U && ((address >> index)(0) === 1.U)
        val dataOn = index < 16.U && ((data >> index)(0) === 1.U)
        MuxLookup(kind, 0.U(8.W))(Seq(
                                      AwTxnKind.globalControl -> 1.U(8.W),
                                      AwTxnKind.globalCurrent -> globalCurrent.U(8.W),
                                      AwTxnKind.channelCurrent -> channelCurrent.U(8.W),
                                      AwTxnKind.addressBrightness -> Mux(addressOn, onBrightness.U(8.W), offBrightness.U(8.W)),
                                      AwTxnKind.dataBrightness -> Mux(dataOn, onBrightness.U(8.W), offBrightness.U(8.W)),
                                      AwTxnKind.update -> 0.U(8.W)
                                  ))
    }

    val dataIndex = byteIndex - 2.U
    val selectedByte = MuxCase(payload(kind, dataIndex, addressValue, dataValue), Seq(
                                   (byteIndex === 0.U) -> Cat(deviceAddress, 0.U(1.W)),
                                   (byteIndex === 1.U) -> registerAddress
                               ))

    io.sclDriveLow := sclDriveLow
    io.sdaDriveLow := sdaDriveLow
    io.busy := state =/= idle
    io.done := done
    done := false.B

    when(state === idle) {
        tickCount := 0.U
        sclDriveLow := false.B
        sdaDriveLow := false.B
        when(io.start) {
            deviceAddress := io.deviceAddress
            registerAddress := io.registerAddress
            length := io.length
            kind := io.kind
            addressValue := io.addressValue
            dataValue := io.dataValue
            byteIndex := 0.U
            bitIndex := 7.U
            state := start1
        }
    }.elsewhen(tickCount === (halfDivider - 1).U) {
        tickCount := 0.U
        switch(state) {
            is(start1) {
                sclDriveLow := false.B
                sdaDriveLow := false.B
                state := start2
            }
            is(start2) {
                sclDriveLow := false.B
                sdaDriveLow := true.B
                state := start3
            }
            is(start3) {
                sclDriveLow := true.B
                sdaDriveLow := true.B
                state := loadByte
            }
            is(loadByte) {
                currentByte := selectedByte
                bitIndex := 7.U
                sclDriveLow := true.B
                state := bitSetup
            }
            is(bitSetup) {
                sclDriveLow := true.B
                sdaDriveLow := !currentByte(bitIndex)
                state := bitHigh
            }
            is(bitHigh) {
                sclDriveLow := false.B
                state := bitLow
            }
            is(bitLow) {
                sclDriveLow := true.B
                when(bitIndex === 0.U) {
                    state := ackSetup
                }.otherwise {
                    bitIndex := bitIndex - 1.U
                    state := bitSetup
                }
            }
            is(ackSetup) {
                sclDriveLow := true.B
                sdaDriveLow := false.B
                state := ackHigh
            }
            is(ackHigh) {
                sclDriveLow := false.B
                state := ackLow
            }
            is(ackLow) {
                sclDriveLow := true.B
                when(byteIndex === (length + 1.U)) {
                    sdaDriveLow := true.B
                    state := stop1
                }.otherwise {
                    byteIndex := byteIndex + 1.U
                    state := loadByte
                }
            }
            is(stop1) {
                sclDriveLow := true.B
                sdaDriveLow := true.B
                state := stop2
            }
            is(stop2) {
                sclDriveLow := false.B
                sdaDriveLow := true.B
                state := stop3
            }
            is(stop3) {
                sclDriveLow := false.B
                sdaDriveLow := false.B
                done := true.B
                state := idle
            }
        }
    }.otherwise {
        tickCount := tickCount + 1.U
    }
}

class Aw21024Panel(
    clkHz: Int,
    i2cHz: Int = 100000,
    powerupDelayCycles: Int = 100000,
    oscillatorDelayCycles: Int = 10000,
    sampleIntervalMs: Int = 5,
    holdIntervalMs: Int = 50,
    addressDeviceAddress: Int = 0x30,
    dataDeviceAddress: Int = 0x31,
    onBrightness: Int = 0x20,
    offBrightness: Int = 0x00,
    globalCurrent: Int = 0x40,
    channelCurrent: Int = 0xff
) extends Module {
    val io = IO(new Bundle {
                    val addressValue = Input(UInt(22.W))
                    val dataValue = Input(UInt(16.W))
                    val sclDriveLow = Output(Bool())
                    val sdaDriveLow = Output(Bool())
                    val addressEnable = Output(Bool())
                    val dataEnable = Output(Bool())
                })

    private val powerupLimit = math.max(1, powerupDelayCycles)
    private val oscillatorLimit = math.max(1, oscillatorDelayCycles)

    private val sampleCycles = math.max(1, (clkHz / 1000) * sampleIntervalMs)
    private val holdCycles = math.max(1, (clkHz / 1000) * holdIntervalMs)
    private val delayWidth = log2Ceil(math.max(powerupLimit, oscillatorLimit) + 1).max(1)
    private val sampleWidth = log2Ceil(sampleCycles + 1).max(1)
    private val holdWidth = log2Ceil(holdCycles + 1).max(1)

    private val writer = Module(new Aw21024I2cBurstWriter(
                                    clkHz = clkHz,
                                    i2cHz = i2cHz,
                                    onBrightness = onBrightness,
                                    offBrightness = offBrightness,
                                    globalCurrent = globalCurrent,
                                    channelCurrent = channelCurrent
                                ))

    val powerWait :: startTransaction :: waitTransaction :: oscillatorWait :: idle :: Nil = Enum(5)
    val state = RegInit(powerWait)
    val initIndex = RegInit(0.U(4.W))
    val refreshIndex = RegInit(0.U(3.W))
    val delayCount = RegInit(0.U(delayWidth.W))
    val sampleCount = RegInit(0.U(sampleWidth.W))
    val holdCount = RegInit(holdCycles.U(holdWidth.W))
    val displayedAddress = RegInit(0.U(22.W))
    val displayedData = RegInit(0.U(16.W))
    val sampledAddress = RegInit(0.U(22.W))
    val sampledData = RegInit(0.U(16.W))
    val refreshAddress = RegInit(0.U(22.W))
    val refreshData = RegInit(0.U(16.W))
    val displayValid = RegInit(false.B)
    val refreshing = RegInit(false.B)
    val startWriter = WireDefault(false.B)

    writer.io.start := startWriter
    writer.io.addressValue := refreshAddress
    writer.io.dataValue := refreshData

    val transactionDevice = WireDefault(addressDeviceAddress.U(7.W))
    val transactionRegister = WireDefault(0.U(8.W))
    val transactionLength = WireDefault(1.U(5.W))
    val transactionKind = WireDefault(AwTxnKind.update)
    val initDevice = Mux(initIndex(0), dataDeviceAddress.U(7.W), addressDeviceAddress.U(7.W))

    switch(initIndex) {
        is(0.U, 1.U) {
            transactionDevice := initDevice
            transactionRegister := "h00".U
            transactionKind := AwTxnKind.globalControl
        }
        is(2.U, 3.U) {
            transactionDevice := initDevice
            transactionRegister := "h6e".U
            transactionKind := AwTxnKind.globalCurrent
        }
        is(4.U, 5.U) {
            transactionDevice := initDevice
            transactionRegister := "h4a".U
            transactionLength := 24.U
            transactionKind := AwTxnKind.channelCurrent
        }
        is(6.U) {
            transactionDevice := addressDeviceAddress.U
            transactionRegister := "h01".U
            transactionLength := 24.U
            transactionKind := AwTxnKind.addressBrightness
        }
        is(7.U) {
            transactionDevice := addressDeviceAddress.U
            transactionRegister := "h49".U
        }
        is(8.U) {
            transactionDevice := dataDeviceAddress.U
            transactionRegister := "h01".U
            transactionLength := 24.U
            transactionKind := AwTxnKind.dataBrightness
        }
        is(9.U) {
            transactionDevice := dataDeviceAddress.U
            transactionRegister := "h49".U
        }
    }

    when(refreshing) {
        switch(refreshIndex) {
            is(0.U) {
                transactionDevice := addressDeviceAddress.U
                transactionRegister := "h01".U
                transactionLength := 24.U
                transactionKind := AwTxnKind.addressBrightness
            }
            is(1.U) {
                transactionDevice := addressDeviceAddress.U
                transactionRegister := "h49".U
            }
            is(2.U) {
                transactionDevice := dataDeviceAddress.U
                transactionRegister := "h01".U
                transactionLength := 24.U
                transactionKind := AwTxnKind.dataBrightness
            }
            is(3.U) {
                transactionDevice := dataDeviceAddress.U
                transactionRegister := "h49".U
            }
        }
    }

    writer.io.deviceAddress := transactionDevice
    writer.io.registerAddress := transactionRegister
    writer.io.length := transactionLength
    writer.io.kind := transactionKind

    io.sclDriveLow := writer.io.sclDriveLow
    io.sdaDriveLow := writer.io.sdaDriveLow
    io.addressEnable := state =/= powerWait
    io.dataEnable := state =/= powerWait

    when(sampleCount === (sampleCycles - 1).U) {
        sampleCount := 0.U
        sampledAddress := io.addressValue
        sampledData := io.dataValue
    }.otherwise {
        sampleCount := sampleCount + 1.U
    }
    when(holdCount =/= holdCycles.U) { holdCount := holdCount + 1.U }

    switch(state) {
        is(powerWait) {
            delayCount := delayCount + 1.U
            when(delayCount === (powerupLimit - 1).U) {
                delayCount := 0.U
                initIndex := 0.U
                refreshing := false.B
                state := startTransaction
            }
        }
        is(startTransaction) {
            when(!writer.io.busy) {
                startWriter := true.B
                state := waitTransaction
            }
        }
        is(waitTransaction) {
            when(writer.io.done) {
                when(refreshing) {
                    when(refreshIndex === 3.U) {
                        displayedAddress := refreshAddress
                        displayedData := refreshData
                        displayValid := true.B
                        holdCount := 0.U
                        refreshing := false.B
                        state := idle
                    }.otherwise {
                        refreshIndex := refreshIndex + 1.U
                        state := startTransaction
                    }
                }.otherwise {
                    when(initIndex === 1.U) {
                        delayCount := 0.U
                        state := oscillatorWait
                    }.elsewhen(initIndex === 9.U) {
                        displayedAddress := refreshAddress
                        displayedData := refreshData
                        displayValid := true.B
                        holdCount := 0.U
                        state := idle
                    }.otherwise {
                        initIndex := initIndex + 1.U
                        state := startTransaction
                    }
                }
            }
        }
        is(oscillatorWait) {
            delayCount := delayCount + 1.U
            when(delayCount === (oscillatorLimit - 1).U) {
                delayCount := 0.U
                initIndex := 2.U
                state := startTransaction
            }
        }
        is(idle) {
            val changed = !displayValid || sampledAddress =/= displayedAddress || sampledData =/= displayedData
            when(changed && holdCount === holdCycles.U && !writer.io.busy) {
                refreshAddress := sampledAddress
                refreshData := sampledData
                refreshIndex := 0.U
                refreshing := true.B
                state := startTransaction
            }
        }
    }
}
