/*
Copyright (c) 2016  whitequark <whitequark@whitequark.org>
Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:
The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/

use std::io::{Read, Result};

const DECOMPRESS_BUF_LEN: usize = 32 * 1024;

pub struct ZlibReader<'a> {
    decompressor: flate2::Decompress,
    input: &'a [u8],
    buf: Vec<u8>,
    pos: usize,
    len: usize,
}

impl<'a> ZlibReader<'a> {
    pub fn new(decompressor: flate2::Decompress, input: &'a [u8]) -> ZlibReader<'a> {
        Self::with_buffer(decompressor, input, vec![0u8; DECOMPRESS_BUF_LEN])
    }

    pub fn with_buffer(
        decompressor: flate2::Decompress,
        input: &'a [u8],
        mut buf: Vec<u8>,
    ) -> ZlibReader<'a> {
        if buf.len() < DECOMPRESS_BUF_LEN {
            buf.resize(DECOMPRESS_BUF_LEN, 0);
        }
        ZlibReader {
            decompressor,
            input,
            buf,
            pos: 0,
            len: 0,
        }
    }

    pub fn into_parts(mut self) -> Result<(flate2::Decompress, Vec<u8>)> {
        // Consume any zero-output sync-flush trailer left in the compressed input.
        let mut scratch = [0u8; 64];
        while !self.input.is_empty() {
            let in_before = self.decompressor.total_in();
            let out_before = self.decompressor.total_out();
            let status = self
                .decompressor
                .decompress(self.input, &mut scratch, flate2::FlushDecompress::None)
                .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?;
            let consumed = (self.decompressor.total_in() - in_before) as usize;
            let produced = (self.decompressor.total_out() - out_before) as usize;
            self.input = &self.input[consumed..];
            if produced > 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "leftover zlib byte data",
                ));
            }
            if matches!(status, flate2::Status::StreamEnd) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "zlib stream end",
                ));
            }
            if consumed == 0 {
                break;
            }
        }
        if self.input.is_empty() && self.pos == self.len {
            Ok((self.decompressor, self.buf))
        } else {
            Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "leftover zlib byte data",
            ))
        }
    }

    pub fn into_inner(self) -> Result<flate2::Decompress> {
        Ok(self.into_parts()?.0)
    }

    fn refill(&mut self) -> std::io::Result<usize> {
        self.pos = 0;
        self.len = 0;
        loop {
            if self.input.is_empty() {
                return Ok(0);
            }
            let in_before = self.decompressor.total_in();
            let out_before = self.decompressor.total_out();
            let result = self.decompressor.decompress(
                self.input,
                &mut self.buf,
                flate2::FlushDecompress::None,
            );
            let consumed = (self.decompressor.total_in() - in_before) as usize;
            let produced = (self.decompressor.total_out() - out_before) as usize;
            self.input = &self.input[consumed..];
            match result {
                Ok(flate2::Status::Ok) => {
                    if produced > 0 {
                        self.len = produced;
                        return Ok(produced);
                    }
                    if consumed == 0 {
                        return Ok(0);
                    }
                }
                Ok(flate2::Status::BufError) => return Ok(0),
                Err(error) => {
                    return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, error))
                }
                Ok(flate2::Status::StreamEnd) => {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "zlib stream end",
                    ))
                }
            }
        }
    }

    #[inline]
    pub fn read_u8(&mut self) -> std::io::Result<u8> {
        if self.pos == self.len && self.refill()? == 0 {
            return Err(std::io::Error::from(std::io::ErrorKind::UnexpectedEof));
        }
        let byte = self.buf[self.pos];
        self.pos += 1;
        Ok(byte)
    }

    #[inline]
    pub fn read_bytes(&mut self, mut output: &mut [u8]) -> std::io::Result<()> {
        while !output.is_empty() {
            if self.pos == self.len && self.refill()? == 0 {
                return Err(std::io::Error::from(std::io::ErrorKind::UnexpectedEof));
            }
            let take = (self.len - self.pos).min(output.len());
            output[..take].copy_from_slice(&self.buf[self.pos..self.pos + take]);
            self.pos += take;
            output = &mut output[take..];
        }
        Ok(())
    }
}

impl Read for ZlibReader<'_> {
    fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
        if output.is_empty() {
            return Ok(0);
        }
        if self.pos == self.len && self.refill()? == 0 {
            return Ok(0);
        }
        let take = (self.len - self.pos).min(output.len());
        output[..take].copy_from_slice(&self.buf[self.pos..self.pos + take]);
        self.pos += take;
        Ok(take)
    }
}
