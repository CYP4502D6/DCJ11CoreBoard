package dcj11.task7.ip

import chisel3._
import chisel3.util._

private object Aw21024TxnKind {
  val gcr = 0.U(3.W)
  val gccr = 1.U(3.W)
  val col = 2.U(3.W)
  val brAddr = 3.U(3.W)
  val brData = 4.U(3.W)
  val update = 5.U(3.W)
}

private class Aw21024I2cBurstWriter(
  clkHz: Int,
  i2cHz: Int,
  ledOnBrightness: Int,
  ledOffBrightness: Int,
  globalCurrent: Int,
  channelCurrent: Int
) extends Module {
  private val halfDivider = math.max(1, clkHz / math.max(1, i2cHz * 2))
  private val tickWidth = log2Ceil(halfDivider + 1).max(1)

  val io = IO(new Bundle {
    val start = Input(Bool())
    val devAddr = Input(UInt(7.W))
    val regAddr = Input(UInt(8.W))
    val length = Input(UInt(5.W))
    val kind = Input(UInt(3.W))
    val addrValue = Input(UInt(22.W))
    val dataValue = Input(UInt(16.W))
    val sclDriveLow = Output(Bool())
    val sdaDriveLow = Output(Bool())
    val busy = Output(Bool())
    val done = Output(Bool())
  })

  val (idle :: start1 :: start2 :: start3 :: loadByte ::
    bitSetup :: bitHigh :: bitLow :: ackSetup :: ackHigh ::
    ackLow :: stop1 :: stop2 :: stop3 :: Nil) = Enum(14)

  val state = RegInit(idle)
  val tickCount = RegInit(0.U(tickWidth.W))
  val sclDriveLowReg = RegInit(false.B)
  val sdaDriveLowReg = RegInit(false.B)
  val devAddrReg = RegInit(0.U(7.W))
  val regAddrReg = RegInit(0.U(8.W))
  val lengthReg = RegInit(1.U(5.W))
  val kindReg = RegInit(Aw21024TxnKind.update)
  val addrValueReg = RegInit(0.U(22.W))
  val dataValueReg = RegInit(0.U(16.W))
  val currentByte = RegInit(0.U(8.W))
  val byteIndex = RegInit(0.U(6.W))
  val bitIndex = RegInit(7.U(3.W))
  val doneReg = RegInit(false.B)

  def txnData(kind: UInt, index: UInt, addrValue: UInt, dataValue: UInt): UInt = {
    val addrOn = index < 22.U && ((addrValue >> index)(0) === 1.U)
    val dataOn = index < 16.U && ((dataValue >> index)(0) === 1.U)
    MuxLookup(kind, 0.U(8.W))(Seq(
      Aw21024TxnKind.gcr -> 1.U(8.W),
      Aw21024TxnKind.gccr -> globalCurrent.U(8.W),
      Aw21024TxnKind.col -> channelCurrent.U(8.W),
      Aw21024TxnKind.brAddr -> Mux(addrOn, ledOnBrightness.U(8.W), ledOffBrightness.U(8.W)),
      Aw21024TxnKind.brData -> Mux(dataOn, ledOnBrightness.U(8.W), ledOffBrightness.U(8.W)),
      Aw21024TxnKind.update -> 0.U(8.W)
    ))
  }

  val dataIndex = byteIndex - 2.U
  val selectedByte = MuxCase(txnData(kindReg, dataIndex, addrValueReg, dataValueReg), Seq(
    (byteIndex === 0.U) -> Cat(devAddrReg, 0.U(1.W)),
    (byteIndex === 1.U) -> regAddrReg
  ))

  io.sclDriveLow := sclDriveLowReg
  io.sdaDriveLow := sdaDriveLowReg
  io.busy := state =/= idle
  io.done := doneReg

  doneReg := false.B

  when(state === idle) {
    tickCount := 0.U
    sclDriveLowReg := false.B
    sdaDriveLowReg := false.B

    when(io.start) {
      devAddrReg := io.devAddr
      regAddrReg := io.regAddr
      lengthReg := io.length
      kindReg := io.kind
      addrValueReg := io.addrValue
      dataValueReg := io.dataValue
      byteIndex := 0.U
      bitIndex := 7.U
      state := start1
    }
  }.elsewhen(tickCount === (halfDivider - 1).U) {
    tickCount := 0.U

    switch(state) {
      is(start1) {
        sclDriveLowReg := false.B
        sdaDriveLowReg := false.B
        state := start2
      }

      is(start2) {
        sclDriveLowReg := false.B
        sdaDriveLowReg := true.B
        state := start3
      }

      is(start3) {
        sclDriveLowReg := true.B
        sdaDriveLowReg := true.B
        state := loadByte
      }

      is(loadByte) {
        currentByte := selectedByte
        bitIndex := 7.U
        sclDriveLowReg := true.B
        state := bitSetup
      }

      is(bitSetup) {
        sclDriveLowReg := true.B
        sdaDriveLowReg := !currentByte(bitIndex)
        state := bitHigh
      }

      is(bitHigh) {
        sclDriveLowReg := false.B
        state := bitLow
      }

      is(bitLow) {
        sclDriveLowReg := true.B
        when(bitIndex === 0.U) {
          state := ackSetup
        }.otherwise {
          bitIndex := bitIndex - 1.U
          state := bitSetup
        }
      }

      is(ackSetup) {
        sclDriveLowReg := true.B
        sdaDriveLowReg := false.B
        state := ackHigh
      }

      is(ackHigh) {
        sclDriveLowReg := false.B
        state := ackLow
      }

      is(ackLow) {
        sclDriveLowReg := true.B
        when(byteIndex === (lengthReg + 1.U)) {
          sdaDriveLowReg := true.B
          state := stop1
        }.otherwise {
          byteIndex := byteIndex + 1.U
          state := loadByte
        }
      }

      is(stop1) {
        sclDriveLowReg := true.B
        sdaDriveLowReg := true.B
        state := stop2
      }

      is(stop2) {
        sclDriveLowReg := false.B
        sdaDriveLowReg := true.B
        state := stop3
      }

      is(stop3) {
        sclDriveLowReg := false.B
        sdaDriveLowReg := false.B
        doneReg := true.B
        state := idle
      }
    }
  }.otherwise {
    tickCount := tickCount + 1.U
  }
}

class Aw21024LedPanel(
  clkHz: Int = 50000000,
  i2cHz: Int = 100000,
  powerupDelayCycles: Int = 100000,
  oscDelayCycles: Int = 10000,
  sampleIntervalMs: Int = 20,
  holdIntervalMs: Int = 100,
  addrDeviceAddr: Int = 0x30,
  dataDeviceAddr: Int = 0x31,
  ledOnBrightness: Int = 0x20,
  ledOffBrightness: Int = 0x00,
  globalCurrent: Int = 0x40,
  channelCurrent: Int = 0xff
) extends RawModule {
  override def desiredName: String = "aw21024_led_panel"

  val clk = IO(Input(Clock()))
  val reset_n = IO(Input(Bool()))
  val addr_value = IO(Input(UInt(22.W)))
  val data_value = IO(Input(UInt(16.W)))
  val i2c_scl_drive_low = IO(Output(Bool()))
  val i2c_sda_drive_low = IO(Output(Bool()))
  val addr_en = IO(Output(Bool()))
  val data_en = IO(Output(Bool()))

  private val powerupLimit = math.max(1, powerupDelayCycles)
  private val oscLimit = math.max(1, oscDelayCycles)
  private val sampleCycles = math.max(1, (clkHz / 1000) * sampleIntervalMs)
  private val holdCycles = math.max(1, (clkHz / 1000) * holdIntervalMs)

  withClockAndReset(clk, (!reset_n).asBool) {
    val writer = Module(new Aw21024I2cBurstWriter(
      clkHz = clkHz,
      i2cHz = i2cHz,
      ledOnBrightness = ledOnBrightness,
      ledOffBrightness = ledOffBrightness,
      globalCurrent = globalCurrent,
      channelCurrent = channelCurrent
    ))

    val powerWait :: startTxn :: waitTxn :: oscWait :: idle :: Nil = Enum(5)
    val state = RegInit(powerWait)
    val initIndex = RegInit(0.U(4.W))
    val refreshIndex = RegInit(0.U(3.W))
    val delayCount = RegInit(0.U(log2Ceil(math.max(powerupLimit, oscLimit) + 1).max(1).W))
    val sampleCount = RegInit(0.U(log2Ceil(sampleCycles + 1).max(1).W))
    val holdCount = RegInit(holdCycles.U(log2Ceil(holdCycles + 1).max(1).W))
    val displayedAddr = RegInit(0.U(22.W))
    val displayedData = RegInit(0.U(16.W))
    val sampledAddr = RegInit(0.U(22.W))
    val sampledData = RegInit(0.U(16.W))
    val refreshAddr = RegInit(0.U(22.W))
    val refreshData = RegInit(0.U(16.W))
    val displayValid = RegInit(false.B)
    val inRefresh = RegInit(false.B)
    val startWriter = WireDefault(false.B)

    writer.io.start := startWriter
    writer.io.addrValue := refreshAddr
    writer.io.dataValue := refreshData

    val txnDev = WireDefault(addrDeviceAddr.U(7.W))
    val txnReg = WireDefault(0.U(8.W))
    val txnLen = WireDefault(1.U(5.W))
    val txnKind = WireDefault(Aw21024TxnKind.update)

    val initDev = Mux(initIndex(0), dataDeviceAddr.U(7.W), addrDeviceAddr.U(7.W))
    switch(initIndex) {
      is(0.U, 1.U) {
        txnDev := initDev
        txnReg := "h00".U
        txnLen := 1.U
        txnKind := Aw21024TxnKind.gcr
      }
      is(2.U, 3.U) {
        txnDev := initDev
        txnReg := "h6e".U
        txnLen := 1.U
        txnKind := Aw21024TxnKind.gccr
      }
      is(4.U, 5.U) {
        txnDev := initDev
        txnReg := "h4a".U
        txnLen := 24.U
        txnKind := Aw21024TxnKind.col
      }
      is(6.U) {
        txnDev := addrDeviceAddr.U
        txnReg := "h01".U
        txnLen := 24.U
        txnKind := Aw21024TxnKind.brAddr
      }
      is(7.U) {
        txnDev := addrDeviceAddr.U
        txnReg := "h49".U
        txnLen := 1.U
        txnKind := Aw21024TxnKind.update
      }
      is(8.U) {
        txnDev := dataDeviceAddr.U
        txnReg := "h01".U
        txnLen := 24.U
        txnKind := Aw21024TxnKind.brData
      }
      is(9.U) {
        txnDev := dataDeviceAddr.U
        txnReg := "h49".U
        txnLen := 1.U
        txnKind := Aw21024TxnKind.update
      }
    }

    when(inRefresh) {
      switch(refreshIndex) {
        is(0.U) {
          txnDev := addrDeviceAddr.U
          txnReg := "h01".U
          txnLen := 24.U
          txnKind := Aw21024TxnKind.brAddr
        }
        is(1.U) {
          txnDev := addrDeviceAddr.U
          txnReg := "h49".U
          txnLen := 1.U
          txnKind := Aw21024TxnKind.update
        }
        is(2.U) {
          txnDev := dataDeviceAddr.U
          txnReg := "h01".U
          txnLen := 24.U
          txnKind := Aw21024TxnKind.brData
        }
        is(3.U) {
          txnDev := dataDeviceAddr.U
          txnReg := "h49".U
          txnLen := 1.U
          txnKind := Aw21024TxnKind.update
        }
      }
    }

    writer.io.devAddr := txnDev
    writer.io.regAddr := txnReg
    writer.io.length := txnLen
    writer.io.kind := txnKind

    i2c_scl_drive_low := writer.io.sclDriveLow
    i2c_sda_drive_low := writer.io.sdaDriveLow
    addr_en := state =/= powerWait
    data_en := state =/= powerWait

    when(sampleCount === (sampleCycles - 1).U) {
      sampleCount := 0.U
      sampledAddr := addr_value
      sampledData := data_value
    }.otherwise {
      sampleCount := sampleCount + 1.U
    }

    when(holdCount =/= holdCycles.U) {
      holdCount := holdCount + 1.U
    }

    switch(state) {
      is(powerWait) {
        delayCount := delayCount + 1.U
        when(delayCount === (powerupLimit - 1).U) {
          delayCount := 0.U
          initIndex := 0.U
          inRefresh := false.B
          state := startTxn
        }
      }

      is(startTxn) {
        when(!writer.io.busy) {
          startWriter := true.B
          state := waitTxn
        }
      }

      is(waitTxn) {
        when(writer.io.done) {
          when(inRefresh) {
            when(refreshIndex === 3.U) {
              displayedAddr := refreshAddr
              displayedData := refreshData
              displayValid := true.B
              holdCount := 0.U
              inRefresh := false.B
              state := idle
            }.otherwise {
              refreshIndex := refreshIndex + 1.U
              state := startTxn
            }
          }.otherwise {
            when(initIndex === 1.U) {
              delayCount := 0.U
              state := oscWait
            }.elsewhen(initIndex === 9.U) {
              displayedAddr := refreshAddr
              displayedData := refreshData
              displayValid := true.B
              holdCount := 0.U
              state := idle
            }.otherwise {
              initIndex := initIndex + 1.U
              state := startTxn
            }
          }
        }
      }

      is(oscWait) {
        delayCount := delayCount + 1.U
        when(delayCount === (oscLimit - 1).U) {
          delayCount := 0.U
          initIndex := 2.U
          state := startTxn
        }
      }

      is(idle) {
        val displayChanged = !displayValid ||
          (sampledAddr =/= displayedAddr) ||
          (sampledData =/= displayedData)
        when(displayChanged && holdCount === holdCycles.U && !writer.io.busy) {
          refreshAddr := sampledAddr
          refreshData := sampledData
          refreshIndex := 0.U
          inRefresh := true.B
          state := startTxn
        }
      }
    }
  }

}
