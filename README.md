
# SPIFlashSafeFile

The SPIFlashSafeFile (SFSF) class implements a redundant [wear leveling](https://en.wikipedia.org/wiki/Wear_leveling) file system that stores a single serialisable critical object reliably on a SPI Flash device (using either the built-in [hardware.spiflash](https://electricimp.com/docs/api/hardware/spiflash) object on imp003+, or an external SPI Flash plus the [SPIFlash library](https://github.com/electricimp/spiflash) on the imp001 and imp002).  This class is dependent on the [Serializer library](https://github.com/electricimp/Serializer).

**To add this code to your project, copy the entire `SPIFlashSafeFile.class.nut` file and paste it at the top of your device code just after your library #require statmements.**

#### imp003+
```squirrel
#require "Serializer.class.nut:1.0.0"

// Paste SPIFlashSafeFile.class.nut file here
```

#### imp001 / imp002
```squirrel
#require "Serializer.class.nut:1.0.0"
#require "SPIFlash.class.nut:1.0.1"

// Paste SPIFlashSafeFile.class.nut file here
```

You can view the library’s source code on [GitHub](https://github.com/electricimp/SPIFlashSafeFile).

## Overview of the File System

The SFSF divides the storage into sequential 4k sectors combined into a space. At least three identically sized spaces must be provided so that at least two copies of the object can be stored and an extra left untouched in case of failure during the write function. When an object is written to the storage it is written to at least two copies with CRC's. When it is read back in, the CRC's are checked until one is correct and the data is returned.


# SPIFlashSafeFile

### Constructor: SPIFlashSafeFile(*[start, end, spiflash, spaces=3, copies=2]*)

The SPIFlashSafeFile constructor allows you to specify the start and end bytes of the file system in the SPIFlash, as well as an optional SPIFlash object (if you are not using the built in `hardware.spiflash` object).

The start and end values **must** be on sector boundaries (0x1000, 0x2000, ...), otherwise a `SPIFlashSafeFile.ERR_INVALID_BOUNDARY` error will be thrown. The number of sectors also must be evenly divisible by the number of spaces, which defaults to 3. The number of copies must be greater than one and less than the number of spaces, which defaults to 2.

#### imp003+
```squirrel
// Allocate the first six pages to three spaces of 8kb each. Two copies of each object will be written to flash.
sfsf <- SPIFlashSafeFile(0x0000, 0x6000, 3);
```

#### imp001 / imp002
```squirrel
// Configure the external SPIFlash
flash <- SPIFlash(hardware.spi257, hardware.pin8);
flash.configure(30000);

// Allocate the first six pages to six spaces of 4kb each. Three copies of each object will be written to flash.
sfsf <- SPIFlashSafeFile(0x0000, 0x6000, flash, 6, 3);
```

## Class Methods

### write(object)

The *write* function serialises the provided object and stores it multiple times on the flash. If it is unable to store the object it will throw an exception.

```squirrel
local data = "Hello, world.";
sfsf.write(data);
```


### read(*[def=null]*)

The *read* function returns the last object written to the flash. If nothing can be read from the flash storage then the provided default value (or null) is returned.

```squirrel
local data = sfsf.read();
server.log(format("The data stored is a %s, containing: %s", typeof data, data.tostring()))
```


# TODO:
- write() doesn't retry on failure. It should continue to write copies until it runs out of space or succeeds.


# License

The SPIFlash class is licensed under [MIT License](./LICENSE).
