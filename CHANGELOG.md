# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-19

First release of the native Swift rewrite.

### Added

- Processes page with Windows 11 grouping: Apps, Background processes and System
  processes. Apps collect their helpers through bundle, responsible process and
  parent process. CPU, Memory, Disk, Network, GPU and Power usage columns are
  heat-shaded, sortable and resizable, and more columns can be switched on from
  the header menu.
- Per-process disk I/O and, on Apple silicon, per-process GPU usage.
- Performance page with 60-second graphs for CPU (overall or per logical
  processor), memory (with a composition bar), every physical disk (active time
  and transfer rate), every connected network adapter and every GPU (with
  renderer and tiler engines on Apple GPUs).
- App history: CPU time, network and disk traffic per app, kept between launches.
- Startup apps: launch agents and daemons with readable names, publishers from
  code signatures, vendor grouping, and enable/disable.
- Users, Details and Services pages.
- Efficiency mode (Darwin background policy), suspend/resume, priorities,
  end process tree, force quit, run new task with optional admin rights.
- Settings: theme, start page, update speed, always on top, menu bar CPU graph.
- Universal build (Apple silicon and Intel), CI on both architectures, tagged
  releases with a .dmg and a .zip.
