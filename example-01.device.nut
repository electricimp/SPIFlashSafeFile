#require "Serializer.class.nut:1.0.0"
#require "SPIFlashSafeFile.class.nut:1.0.0"

sfsf <- SPIFlashSafeFile(0 * SPIFLASHSAFEFILE_SECTOR_SIZE, 5 * SPIFLASHSAFEFILE_SECTOR_SIZE, 5);

server.log("========[ Writing ]=========")
try {
    local rand = math.rand()%100;
    local write = "Hello, world: " + rand;
    server.log(format("WRITE: %s => %s", typeof write, write.tostring()));
    sfsf.write(write);
} catch (e) {
    server.error(e);
}
server.log("========[ Done writing ]=========\n\n")

server.log("========[ Reading ]=========")
try {
    local read = sfsf.read();
    server.log(format("READ: %s => %s", typeof read, read.tostring()))
} catch (e) {
    server.error(e);
}
server.log("========[ Done reading ]=========\n\n")

