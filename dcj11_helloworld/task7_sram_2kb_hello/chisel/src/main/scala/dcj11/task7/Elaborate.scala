package dcj11.task7

import circt.stage.ChiselStage
import dcj11.task7.ip._

object Elaborate extends App {
  val targetDir = "../generated"
  ChiselStage.emitSystemVerilogFile(
    new UartRx(clkHz = 50000000, baud = 115200),
    firtoolOpts = Array("-disable-all-randomization", "-strip-debug-info"),
    args = Array("--target-dir", targetDir)
  )
  ChiselStage.emitSystemVerilogFile(
    new UartTx(clkHz = 50000000, baud = 115200),
    firtoolOpts = Array("-disable-all-randomization", "-strip-debug-info"),
    args = Array("--target-dir", targetDir)
  )
  ChiselStage.emitSystemVerilogFile(
    new Kl11Lite(clkHz = 50000000, baud = 115200),
    firtoolOpts = Array("-disable-all-randomization", "-strip-debug-info"),
    args = Array("--target-dir", targetDir)
  )
  ChiselStage.emitSystemVerilogFile(
    new Aw21024LedPanel(
      clkHz = 50000000,
      i2cHz = 100000,
      powerupDelayCycles = 100000,
      oscDelayCycles = 10000,
      sampleIntervalMs = 20,
      holdIntervalMs = 100
    ),
    firtoolOpts = Array("-disable-all-randomization", "-strip-debug-info"),
    args = Array("--target-dir", targetDir)
  )
}
