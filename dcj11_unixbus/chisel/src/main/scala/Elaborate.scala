package dcj11.unix22

import circt.stage.ChiselStage

object Elaborate extends App {
    ChiselStage.emitSystemVerilogFile(
        new Dcj11PeripheralCore(BoardConfig()),
        firtoolOpts = Array(
                "-disable-all-randomization",
                "-strip-debug-info",
                "--lowering-options=disallowLocalVariables,disallowDeclAssignments,disallowPackedArrays"
            ),
        args = Array("--target-dir", "../generated")
    )
}
