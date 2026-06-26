package dcj11.task7.ip

import chisel3._
import chisel3.util._

class UartTx(clkHz: Int, baud: Int) extends Module {
  private val bitTicks = math.max(1, (clkHz + baud / 2) / baud)
  private val countWidth = log2Ceil(bitTicks + 1).max(1)

  val io = IO(new Bundle {
    val start = Input(Bool())
    val data = Input(UInt(8.W))
    val tx = Output(Bool())
    val ready = Output(Bool())
  })

  val busy = RegInit(false.B)
  val txReg = RegInit(true.B)
  val bitTimer = RegInit(0.U(countWidth.W))
  val bitIndex = RegInit(0.U(4.W))
  val shifter = RegInit("b1111111111".U(10.W))

  io.tx := txReg
  io.ready := !busy

  when(io.start && !busy) {
    busy := true.B
    shifter := Cat(1.U(1.W), io.data, 0.U(1.W))
    txReg := false.B
    bitTimer := (bitTicks - 1).U
    bitIndex := 0.U
  }.elsewhen(busy) {
    when(bitTimer === 0.U) {
      bitTimer := (bitTicks - 1).U
      shifter := Cat(1.U(1.W), shifter(9, 1))
      bitIndex := bitIndex + 1.U
      txReg := shifter(1)

      when(bitIndex === 9.U) {
        busy := false.B
        txReg := true.B
      }
    }.otherwise {
      bitTimer := bitTimer - 1.U
    }
  }
}

class UartRx(clkHz: Int, baud: Int) extends Module {
  private val bitTicks = math.max(1, (clkHz + baud / 2) / baud)
  private val halfTicks = math.max(1, bitTicks / 2)
  private val countWidth = log2Ceil(bitTicks + 1).max(1)

  val io = IO(new Bundle {
    val rx = Input(Bool())
    val data = Output(UInt(8.W))
    val valid = Output(Bool())
  })

  val rxMeta = RegNext(io.rx, true.B)
  val rxSync = RegNext(rxMeta, true.B)
  val dataReg = RegInit(0.U(8.W))
  val bitTimer = RegInit(0.U(countWidth.W))
  val bitIndex = RegInit(0.U(3.W))
  val idleHighCount = RegInit(0.U(countWidth.W))
  val validReg = RegInit(false.B)

  val idle :: start :: data :: stop :: Nil = Enum(4)
  val state = RegInit(idle)

  io.data := dataReg
  io.valid := validReg

  validReg := false.B

  when(rxSync) {
    when(idleHighCount =/= (bitTicks - 1).U) {
      idleHighCount := idleHighCount + 1.U
    }
  }.otherwise {
    idleHighCount := 0.U
  }

  switch(state) {
    is(idle) {
      when(!rxSync && idleHighCount === (bitTicks - 1).U) {
        dataReg := 0.U
        bitTimer := (halfTicks - 1).U
        state := start
      }
    }
    is(start) {
      when(bitTimer === 0.U) {
        when(!rxSync) {
          bitTimer := (bitTicks - 1).U
          bitIndex := 0.U
          state := data
        }.otherwise {
          state := idle
        }
      }.otherwise {
        bitTimer := bitTimer - 1.U
      }
    }
    is(data) {
      when(bitTimer === 0.U) {
        dataReg := dataReg.bitSet(bitIndex, rxSync)
        bitTimer := (bitTicks - 1).U
        when(bitIndex === 7.U) {
          state := stop
        }.otherwise {
          bitIndex := bitIndex + 1.U
        }
      }.otherwise {
        bitTimer := bitTimer - 1.U
      }
    }
    is(stop) {
      when(bitTimer === 0.U) {
        when(rxSync) {
          validReg := true.B
        }
        state := idle
      }.otherwise {
        bitTimer := bitTimer - 1.U
      }
    }
  }
}
