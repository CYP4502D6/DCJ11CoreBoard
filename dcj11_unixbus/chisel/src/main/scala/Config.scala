package dcj11.unix22

import chisel3._
import chisel3.util._

case class BoardConfig(
    clockHz: Int = 50000000,
    uartBaud: Int = 115200,

    uartTxMaskSoftwareParity: Boolean = true,
    sdInitHz: Int = 400000,
    sdRunHz: Int = 4000000,
    sdPowerUpDelayMs: Int = 10,
    sdRetryDelayMs: Int = 250,
    rpImageSectors: Int = 340154,
    rpSectors: Int = 22,
    rpTracks: Int = 19,
    rpCylinders: Int = 815
) {
    require(clockHz > 0)
    require(sdPowerUpDelayMs >= 1)
    require(sdRetryDelayMs >= 1)
    require(rpSectors * rpTracks * rpCylinders == 340670)
    val rpNominalSectors: Int = rpSectors * rpTracks * rpCylinders
}

object Pdp11 {
    def octal(s: String): BigInt = BigInt(s, 8)

    val Kl11Base: BigInt = octal("17777560")
    val Kw11Lks: BigInt = octal("17777546")
    val Rh11Base: BigInt = octal("17776700")
    val KlRxVector: BigInt = octal("60")
    val KlTxVector: BigInt = octal("64")
    val KwVector: BigInt = octal("100")
    val RhVector: BigInt = octal("254")
}

class MemRequest extends Bundle {
    val write = Bool()
    val address = UInt(22.W)
    val data = UInt(16.W)
    val byteEnable = UInt(2.W)
}

class MemPort extends Bundle {
    val request = Decoupled(new MemRequest)
    val responseValid = Input(Bool())
    val responseData = Input(UInt(16.W))
    val responseError = Input(Bool())
}

class RegisterBus extends Bundle {
    val address = Input(UInt(22.W))
    val readAddress = Input(UInt(22.W))
    val writeAddress = Input(UInt(22.W))
    val readPulse = Input(Bool())
    val writePulse = Input(Bool())
    val dataIn = Input(UInt(16.W))
    val byteEnable = Input(UInt(2.W))
    val hit = Output(Bool())
    val dataOut = Output(UInt(16.W))
}

class BlockRequest extends Bundle {
    val write = Bool()
    val lba = UInt(32.W)
}


class BlockPort extends Bundle {
    val request = Decoupled(new BlockRequest)
    val read = Flipped(Decoupled(UInt(8.W)))
    val write = Decoupled(UInt(8.W))
    val done = Input(Bool())
    val error = Input(Bool())
    val initialized = Input(Bool())
}
