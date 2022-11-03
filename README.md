# Pokemon Mini for Analogue Pocket

Ported from the original core developed by [Grieverheart](https://github.com/Grieverheart). Latest upstream available at https://github.com/MiSTer-devel/PokemonMini_MiSTer.

Please report any issues encountered to this repo. Most likely any problems are a result of my port, not the original core. Issues will be upstreamed as necessary.

## Installation

### Easy mode

I highly recommend the updater tools by [@mattpannella](https://github.com/mattpannella) and [@RetroDriven](https://github.com/RetroDriven). If you're running Windows, use [the RetroDriven GUI](https://github.com/RetroDriven/Pocket_Updater), or if you prefer the CLI, use [the mattpannella tool](https://github.com/mattpannella/pocket_core_autoupdate_net). Either of these will allow you to automatically download and install openFPGA cores onto your Analogue Pocket. Go donate to them if you can

### Manual mode
To install the core, copy the `Assets`, `Cores`, and `Platform` folders over to the root of your SD card. Please note that Finder on macOS automatically _replaces_ folders, rather than merging them like Windows does, so you have to manually merge the folders.

## Usage

ROMs should be placed in `/Assets/poke_mini/common`.

## Features

### Video

The Pokemon Mini LCD refreshes at up to 75Hz, but the Pocket and Dock is limited to ~60Hz. The core uses a four frame buffer to attempt to mitigate tearing effects, but it still will display some artifacts

The `Frame Blend` option is provided to mimic the LCD persistence effect that some games take advantage of. Please note that this will further introduce video artifacts when motion occurs.