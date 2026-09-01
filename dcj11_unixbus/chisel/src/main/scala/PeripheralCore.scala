package dcj11.unix22

import chisel3._
import chisel3.util.Cat

class Dcj11PeripheralCore(cfg: BoardConfig) extends Module {
    val io = IO(new Bundle {
                    val peripheralReset = Input(Bool())

                    val busAddress = Input(UInt(22.W))
                    val busReadAddress = Input(UInt(22.W))
                    val busWriteAddress = Input(UInt(22.W))
                    val busReadPulse = Input(Bool())
                    val busWritePulse = Input(Bool())
                    val busDataIn = Input(UInt(16.W))
                    val busByteEnable = Input(UInt(2.W))
                    val busHit = Output(Bool())
                    val busDataOut = Output(UInt(16.W))

                    val interruptAck = Input(UInt(2.W))
                    val interruptAckVector = Input(UInt(16.W))
                    val eventAck = Input(Bool())
                    val irq = Output(UInt(2.W))
                    val irqVector0 = Output(UInt(16.W))
                    val irqVector1 = Output(UInt(16.W))
                    val eventN = Output(Bool())

                    val rhMemRequestValid = Output(Bool())
                    val rhMemRequestReady = Input(Bool())
                    val rhMemRequestWrite = Output(Bool())
                    val rhMemRequestAddress = Output(UInt(22.W))
                    val rhMemRequestData = Output(UInt(16.W))
                    val rhMemRequestByteEnable = Output(UInt(2.W))
                    val rhMemResponseValid = Input(Bool())
                    val rhMemResponseData = Input(UInt(16.W))
                    val rhMemResponseError = Input(Bool())

                    val uartRx = Input(Bool())
                    val uartTx = Output(Bool())
                    val sdMiso = Input(Bool())
                    val sdSck = Output(Bool())
                    val sdMosi = Output(Bool())
                    val sdCsN = Output(Bool())
                    val sdActive = Output(Bool())

                    val panelAddress = Input(UInt(22.W))
                    val panelData = Input(UInt(16.W))
                    val ledI2cSclDriveLow = Output(Bool())
                    val ledI2cSdaDriveLow = Output(Bool())
                    val ledAddressEnable = Output(Bool())
                    val ledDataEnable = Output(Bool())
                })

    val deviceReset = reset.asBool || io.peripheralReset
    val kl11 = withReset(deviceReset) { Module(new Kl11(cfg)) }
    val kw11 = withReset(deviceReset) { Module(new Kw11(cfg)) }
    val rh11 = withReset(deviceReset) { Module(new Rh11Rp06(cfg)) }
    val sd = Module(new SdBlockDevice(cfg))
    val panel = Module(new Aw21024Panel(cfg.clockHz))

    sd.io.block <> rh11.io.block

    for (device <- Seq(kl11.io.bus, kw11.io.bus, rh11.io.bus)) {
        device.address := io.busAddress
        device.readAddress := io.busReadAddress
        device.writeAddress := io.busWriteAddress
        device.readPulse := io.busReadPulse
        device.writePulse := io.busWritePulse
        device.dataIn := io.busDataIn
        device.byteEnable := io.busByteEnable
    }

    io.busHit := kl11.io.bus.hit || kw11.io.bus.hit || rh11.io.bus.hit
    io.busDataOut := Mux(kl11.io.bus.hit, kl11.io.bus.dataOut,
                         Mux(kw11.io.bus.hit, kw11.io.bus.dataOut,
                             Mux(rh11.io.bus.hit, rh11.io.bus.dataOut, 0.U)))

    kl11.io.acknowledge := io.interruptAck(0)
    kl11.io.acknowledgeVector := io.interruptAckVector
    rh11.io.acknowledge := io.interruptAck(1)
    kw11.io.acknowledge := io.eventAck

    io.irq := Cat(rh11.io.irq, kl11.io.irq)
    io.irqVector0 := kl11.io.vector
    io.irqVector1 := Pdp11.RhVector.U
    io.eventN := kw11.io.eventN

    io.rhMemRequestValid := rh11.io.memory.request.valid
    rh11.io.memory.request.ready := io.rhMemRequestReady
    io.rhMemRequestWrite := rh11.io.memory.request.bits.write
    io.rhMemRequestAddress := rh11.io.memory.request.bits.address
    io.rhMemRequestData := rh11.io.memory.request.bits.data
    io.rhMemRequestByteEnable := rh11.io.memory.request.bits.byteEnable
    rh11.io.memory.responseValid := io.rhMemResponseValid
    rh11.io.memory.responseData := io.rhMemResponseData
    rh11.io.memory.responseError := io.rhMemResponseError

    kl11.io.uartRx := io.uartRx
    io.uartTx := kl11.io.uartTx
    sd.io.miso := io.sdMiso
    io.sdSck := sd.io.sck
    io.sdMosi := sd.io.mosi
    io.sdCsN := sd.io.csN

    io.sdActive := sd.io.active

    panel.io.addressValue := io.panelAddress
    panel.io.dataValue := io.panelData
    io.ledI2cSclDriveLow := panel.io.sclDriveLow
    io.ledI2cSdaDriveLow := panel.io.sdaDriveLow
    io.ledAddressEnable := panel.io.addressEnable
    io.ledDataEnable := panel.io.dataEnable
}
