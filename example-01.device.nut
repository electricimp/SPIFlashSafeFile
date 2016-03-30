#require "Serializer.class.nut:1.0.0"

// Include SPIFlashSafeFile code
// ------------------------------------------------------
// File system information 
const SPIFLASHSAFEFILE_SECTOR_SIZE = 4096;
const SPIFLASHSAFEFILE_SECTOR_META_SIZE = 5; // status (1), id (4)

// Sector metadata values
const SPIFLASHSAFEFILE_ID_INVALID = -1; // 0xFFFFFFFF

const SPIFLASHSAFEFILE_SECTOR_CLEAN = 0xFF;
const SPIFLASHSAFEFILE_SECTOR_STARTED = 0xAA;
const SPIFLASHSAFEFILE_SECTOR_FINISHED = 0x00;

// Default parameters
const SPIFLASHSAFEFILE_MINIMUM_SLOTS = 3;
const SPIFLASHSAFEFILE_DEFAULT_SLOTS = 3;
const SPIFLASHSAFEFILE_DEFAULT_COPIES = 2;
const SPIFLASHSAFEFILE_MINIMUM_COPIES = 2;

const SPIFLASHSAFEFILE_ERR_SERIALIZER = "Serializer class must be defined";
const SPIFLASHSAFEFILE_ERR_INVALID_START = "Invalid start value";
const SPIFLASHSAFEFILE_ERR_INVALID_END = "Invalid end value";
const SPIFLASHSAFEFILE_ERR_INVALID_BOUNDARY = "start and end must be at sector boundaries";
const SPIFLASHSAFEFILE_ERR_INVALID_LENGTH = "Total length must be a multiple of %d sectors";
const SPIFLASHSAFEFILE_ERR_TOO_LARGE = "Can't write an object that large";

class SPIFlashSafeFile {
    
    _flash = null;
    _size = null;
    _start = null;
    _end = null;
    _len = null;
    _copies = 2;
    _slots = 3;
    _sectors = 0;
    _enables = 0;
    _max_data = 0;
    _data_len = 0;
    _last_len = 0;

    static version = [1, 0, 0];

    static className = "SPIFlashSafeFile";


    //--------------------------------------------------------------------------
    // Notes: start and end must be aligned with sector boundaries and the total
    //        size must be a multiple of "slots" sectors.
    constructor(start = null, end = null, flash = null, slots = null, copies = null) {
        
        if (!("Serializer" in getroottable())) throw SPIFLASHSAFEFILE_ERR_SERIALIZER;
        
        // Alow the last three parameter to be optional
        if (typeof flash == "integer") {
            copies = slots;
            slots = flash;
            flash = null;
        }
        if (slots == null || slots < SPIFLASHSAFEFILE_MINIMUM_SLOTS) {
            slots = SPIFLASHSAFEFILE_DEFAULT_SLOTS;
        }
        if (copies == null || copies >= slots || copies < SPIFLASHSAFEFILE_MINIMUM_COPIES) {
            copies = SPIFLASHSAFEFILE_DEFAULT_COPIES;
        }
        
        _flash = flash ? flash : hardware.spiflash;
        _copies = copies;
        _slots = slots;

        _enable();
        _size = _flash.size();
        _disable();
        
        if (start == null) _start = 0;
        else if (start < _size) _start = start;
        else throw SPIFLASHSAFEFILE_ERR_INVALID_START;
        if (_start % SPIFLASHSAFEFILE_SECTOR_SIZE != 0) throw SPIFLASHSAFEFILE_ERR_INVALID_BOUNDARY;
        
        if (end == null) _end = _size;
        else if (end > _start) _end = end;
        else throw SPIFLASHSAFEFILE_ERR_INVALID_END;
        if (_end % SPIFLASHSAFEFILE_SECTOR_SIZE != 0) throw SPIFLASHSAFEFILE_ERR_INVALID_BOUNDARY;

        _len = _end - _start;
        if (_len % (SPIFLASHSAFEFILE_SECTOR_SIZE * _slots) != 0) throw format(SPIFLASHSAFEFILE_ERR_INVALID_LENGTH, _slots);
        
        _data_len = _len / _slots;
        _max_data = _data_len - SPIFLASHSAFEFILE_SECTOR_META_SIZE;
        _sectors = _len / SPIFLASHSAFEFILE_SECTOR_SIZE;
    }
    
    //--------------------------------------------------------------------------
    function dimensions() {
        return { "len": _len, "start": _start, "end": _end, "sectors": _sectors, "copies": _copies, "slots": _slots, "max_data": _max_data }
    }
    
    //--------------------------------------------------------------------------
    function write(object) {
        
        /* General algorithm
        Serialise the object        
        Find the a blank space (best) or the oldest space (next best) and erase it
        Generate and write the metadata and the object
        Repeat once more for the second copy.
        
        */
        
        // Serialise the object
        local object = Serializer.serialize(object);
        local obj_len = object.len();
        if (obj_len > _max_data) throw SPIFLASHSAFEFILE_ERR_TOO_LARGE;

        // Write out [2] copies of the object
        local nextId = null, success = true;
        for (local copy = 0; copy < _copies; copy++) {
            
            // Find a blank space or the lowest Id to erase
            local scan = _scan();
            local space = (scan.emptySpace == null) ? _getSpace(scan.spaces, scan.lowestId) : scan.emptySpace;
            if (!space.isEmpty) {
                // server.log(format("Erasing and reusing addr: %d, id: %d, status: 0x%02X", space.addr, space.id, space.status))
                _erase(space);
            } else {
                // server.log(format("Using addr: %d which is empty", space.addr))
            }
            
            // Work out what the nextId should be
            if (nextId == null) nextId = scan.highestId + 1;
    
            _enable();
            
            // Write the metadata        
            local meta = blob(SPIFLASHSAFEFILE_SECTOR_META_SIZE);
            meta.writen(SPIFLASHSAFEFILE_SECTOR_FINISHED, 'b');
            meta.writen(nextId, 'i');
            local res_meta = _flash.write(space.addr, meta, SPIFLASH_POSTVERIFY)
    
            // Write the data
            local res_data = _flash.write(space.addr + SPIFLASHSAFEFILE_SECTOR_META_SIZE, object, SPIFLASH_POSTVERIFY)
            
            // Check the results
            if (res_meta != 0 || res_data != 0) success = false;
            
            // Record the last length written
            _last_len = obj_len + SPIFLASHSAFEFILE_SECTOR_META_SIZE + 3;
            
            _disable();
            
        }
        
        // _scan();
        return success;
    }


    //--------------------------------------------------------------------------
    function read() {
        
        /* General algorithm
        
        Find the highest id, read it 
        Check the CRC, if it is invalid, find another with the same Id.
        
        */
        local scan = _scan();
        if (scan.highestId == SPIFLASHSAFEFILE_ID_INVALID) return false;
        
        // server.log(format("READ: Hunting for id %d", scan.highestId))
        foreach (space in _scan().spaces) {
            // server.log(format("READ: id %d at addr %d", space.id, space.addr))
            if (space.id == scan.highestId) {
                
                // Read in and convert the length
                _enable();
                local data = _flash.read(space.addr + SPIFLASHSAFEFILE_SECTOR_META_SIZE, 3);
                _disable();
                local len = data.readn('w');

                if (len > 0 && len <= _max_data) {
                    
                    // Now read in the rest of the data
                    data.seek(0, 'e');
                    _enable();
                    _flash.readintoblob(space.addr + SPIFLASHSAFEFILE_SECTOR_META_SIZE + 3, data, len);
                    _disable();
                    
                    try {
                        _last_len = len + SPIFLASHSAFEFILE_SECTOR_META_SIZE + 3;
                        return Serializer.deserialize(data);
                    } catch (e) {
                        server.error(className + ": Error at addr " + space.addr + ", len " + len + ": " + e);
                    }
                }
            }
        }
        
        // No data was found
        server.error(className + ": No object found");
        return false;


    }

    //--------------------------------------------------------------------------
    function last_len() {
        return _last_len;
    }
    
    //--------------------------------------------------------------------------
    function erase(force = false) {
        _enable();
        if (force) {
            for (local sector = 0; sector < _sectors; sector++) {
                _flash.erasesector(_start + (sector * SPIFLASHSAFEFILE_SECTOR_SIZE));
            }
        } else {
            
            foreach (space in _scan().spaces) {
                if (!space.isEmpty) _erase(space);
            }
            
        }
        _disable();
    }
    
    //--------------------------------------------------------------------------
    function _erase(space) {
        _enable();
        // server.log(className + ": Erasing space at " + space.addr);
        for (local addr = 0; addr < _data_len; addr += SPIFLASHSAFEFILE_SECTOR_SIZE) {
            local sector = space.addr + addr;
            _flash.erasesector(sector);
            // server.log(className + ": Erasing sector at " + sector);
        }
        _disable();
    }
    
    //--------------------------------------------------------------------------
    function _scan() {

        // Uses randomness to increase wear levelling
        local offset = (math.rand() % _slots) * _data_len;

        _enable();
        local result = { spaces = [], lowestId = SPIFLASHSAFEFILE_ID_INVALID, highestId = SPIFLASHSAFEFILE_ID_INVALID, emptySpace = null };
        for (local i = 0; i < _len; i += _data_len) {
            
            // Normalise the randomised numbers back to a valid address
            local addr = _start + (offset + i) % _len;

            // Read the status and id
            local meta = _flash.read(addr, SPIFLASHSAFEFILE_SECTOR_META_SIZE);
            local space = {};
            space.addr <- addr;
            space.status <- meta.readn('b');
            space.id  <- meta.readn('i');
            space.isEmpty <- (space.status == SPIFLASHSAFEFILE_SECTOR_CLEAN && space.id == SPIFLASHSAFEFILE_ID_INVALID);
            // server.log(format("SCAN: addr %d, status %d, id %d, isEmpty %s", space.addr, space.status, space.id, space.isEmpty.tostring()))
            
            result.spaces.push(space);
            
            if (space.isEmpty && result.emptySpace == null) result.emptySpace = space;
            if (result.lowestId == SPIFLASHSAFEFILE_ID_INVALID || space.id < result.lowestId) result.lowestId = space.id;
            if (result.highestId == SPIFLASHSAFEFILE_ID_INVALID || space.id > result.highestId) result.highestId = space.id;
        }

        _disable();

        // server.log(format("SCAN RESULT: lowestId %d, highestId %d", result.lowestId, result.highestId))
        
        return result;
    }    
    
    //--------------------------------------------------------------------------
    function _getSpace(spaces, id) {
        foreach (space in spaces) {
            if (space.id == id) return space;
        }
        return null;
    }

    //--------------------------------------------------------------------------
    function _enable() {
        if (_enables++ == 0) {
            _flash.enable();
        }
    }    
    
    //--------------------------------------------------------------------------
    function _disable() {
        if (--_enables == 0)  {
            _flash.disable();
        }
    }    
    
}

// ------------------------------------------------------

// RUNTIME CODE
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

