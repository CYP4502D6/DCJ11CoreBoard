ThisBuild / scalaVersion := "2.13.18"
ThisBuild / organization := "dcj11"

lazy val chiselVersion = "7.13.0"

lazy val root = (project in file("."))
  .settings(
    name := "task7-sram-2kb-hello",
    libraryDependencies += "org.chipsalliance" %% "chisel" % chiselVersion,
    addCompilerPlugin("org.chipsalliance" % "chisel-plugin" % chiselVersion cross CrossVersion.full)
  )
