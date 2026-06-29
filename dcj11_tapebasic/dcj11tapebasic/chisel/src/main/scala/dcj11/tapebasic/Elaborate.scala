package dcj11.tapebasic

import circt.stage.ChiselStage
import dcj11.tapebasic.ip._

object Elaborate extends App {
    private val targetDir = "../generated"
    private val firtoolOptions = Array("-disable-all-randomization", "-strip-debug-info")
    private val targetArgs = Array("--target-dir", targetDir)

    ChiselStage.emitSystemVerilogFile(
        new UartRx(clkHz = 50000000, baud = 115200),
        firtoolOpts = firtoolOptions,
        args = targetArgs
    )
    ChiselStage.emitSystemVerilogFile(
        new UartTx(clkHz = 50000000, baud = 115200),
        firtoolOpts = firtoolOptions,
        args = targetArgs
    )
    ChiselStage.emitSystemVerilogFile(
        new Kl11Console(clkHz = 50000000, baud = 115200),
        firtoolOpts = firtoolOptions,
        args = targetArgs
    )
    ChiselStage.emitSystemVerilogFile(
        new Pc11Reader(),
        firtoolOpts = firtoolOptions,
        args = targetArgs
    )
    ChiselStage.emitSystemVerilogFile(
        new SdTapeStream(),
        firtoolOpts = firtoolOptions,
        args = targetArgs
    )
    ChiselStage.emitSystemVerilogFile(
        new Aw21024Panel(
            clkHz = 50000000,
            i2cHz = 100000,
            powerupDelayCycles = 100000,
            oscDelayCycles = 10000,
            sampleIntervalMs = 20,
            holdIntervalMs = 100
        ),
        firtoolOpts = firtoolOptions,
        args = targetArgs
    )
}
