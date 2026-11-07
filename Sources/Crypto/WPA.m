/*
 
 File:			WPA.m
 Program:		KisMAC
 Author:		Michael Roßberg
                mick@binaervarianz.de
 Changes:       Vitalii Parovishnyk(1012-2015)
 
 Description:	KisMAC is a wireless stumbler for MacOS X.
 
 This file is part of KisMAC.
 
 Most parts of this file are based on aircrack by Christophe Devine.
 
 KisMAC is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License, version 2,
 as published by the Free Software Foundation;
 
 KisMAC is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with KisMAC; if not, write to the Free Software
 Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#include "WPA.h"

#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "80211b.h"
#include <CommonCrypto/CommonDigest.h>	// F-02: polarssl removed
#include <CommonCrypto/CommonHMAC.h>
/*
 * Function: hmac_md5 from rfc2104; uses an MD5 library 
 */ 

void fast_hmac_md5 (
    const unsigned char *text, NSInteger text_len, 
    unsigned char *key, NSInteger key_len,
    void * digest) 
{ 
    // F-02: the hand-rolled HMAC (formerly over polarssl contexts) is exactly
    // CCHmac. Output is identical for every input the original handled;
    // CCHmac additionally handles keys longer than the 64-byte block
    // per RFC 2104 instead of overrunning the pad buffers.
    CCHmac(kCCHmacAlgMD5, key, key_len, text, text_len, digest);
} 

void hmac_md5 (
    const unsigned char *text, NSInteger text_len, 
    unsigned char *key, NSInteger key_len,
    void * digest) 
{ 
    // F-02: the hand-rolled HMAC (formerly over polarssl contexts) is exactly
    // CCHmac. Output is identical for every input the original handled;
    // CCHmac additionally handles keys longer than the 64-byte block
    // per RFC 2104 instead of overrunning the pad buffers.
    // (The original also rewrote a >64-byte key in the caller's buffer as a
    // side effect; no caller relied on that, and CCHmac does not mutate the key.)
    CCHmac(kCCHmacAlgMD5, key, key_len, text, text_len, digest);
} 

void fast_hmac_sha1( unsigned char *text, NSInteger text_len, unsigned char *key, NSInteger key_len, unsigned char *digest) {
    // F-02: the hand-rolled HMAC (formerly over polarssl contexts) is exactly
    // CCHmac. Output is identical for every input the original handled;
    // CCHmac additionally handles keys longer than the 64-byte block
    // per RFC 2104 instead of overrunning the pad buffers.
    CCHmac(kCCHmacAlgSHA1, key, key_len, text, text_len, digest);
}


void hmac_sha1( unsigned char *text, NSInteger text_len, 
    unsigned char *key, NSInteger key_len,
    unsigned char *digest) 
{
    // F-02: the hand-rolled HMAC (formerly over polarssl contexts) is exactly
    // CCHmac. Output is identical for every input the original handled;
    // CCHmac additionally handles keys longer than the 64-byte block
    // per RFC 2104 instead of overrunning the pad buffers.
    CCHmac(kCCHmacAlgSHA1, key, key_len, text, text_len, digest);
}

#pragma mark -

/*  * F(P, S, c, i) = U1 xor U2 xor ... Uc
    * U1 = PRF(P, S || Int(i))
    * U2 = PRF(P, U1)
    * Uc = PRF(P, Uc-1) 
*/

void F(
    char *password,
    const unsigned char *ssid,
    NSInteger ssidlength,
    NSInteger iterations,
    NSInteger count,
    unsigned char *output) 
{
    unsigned char digest[36], 
    digest1[SHA_DIGEST_LENGTH];
    NSInteger i, j; 
    
    for(i = 0; i < strlen(password); ++i) {
        assert((password[i] >= 32) && (password[i] <= 126));
    }
    
    /* U1 = PRF(P, S || NSInteger(i)) */ 
    memcpy(digest, ssid, ssidlength);
    digest[ssidlength] = (unsigned char)((count>>24) & 0xff);   
    digest[ssidlength+1] = (unsigned char)((count>>16) & 0xff); 
    digest[ssidlength+2] = (unsigned char)((count>>8) & 0xff);
    digest[ssidlength+3] = (unsigned char)(count & 0xff); 
    hmac_sha1(digest, ssidlength+4, 
        (unsigned char*) password, (NSInteger) strlen(password), 
        digest1);
    
    /* output = U1 */ 
    memcpy(output, digest1, SHA_DIGEST_LENGTH);
    
    for (i = 1; i < iterations; ++i) {
        /* Un = PRF(P, Un-1) */ 
        hmac_sha1(digest1, SHA_DIGEST_LENGTH,
            (unsigned char*) password, (NSInteger) strlen(password), 
            digest); 
    
        memcpy(digest1, digest, SHA_DIGEST_LENGTH); 
    
        /* output = output xor Un */ 
        for (j = 0; j < SHA_DIGEST_LENGTH; ++j) {
            output[j] ^= digest[j]; 
        }
    }
} 

/* 
 * password - ascii string up to 63 characters in length
 * ssid - octet string up to 32 octets
 * ssidlength - length of ssid in octets
 * output must be 40 octets in length and outputs 256 bits of key   
*/

NSInteger wpaPasswordHash ( 
    char *password,
    const unsigned char *ssid, 
    NSInteger ssidlength, 
    unsigned char *output) 
{ 
    if ((strlen(password) > 63) || (ssidlength > 32))
        return 0; 
        
    F(password, ssid, ssidlength, 4096, 1, output);
    F(password, ssid, ssidlength, 4096, 2, 
        &output[SHA_DIGEST_LENGTH]); 
    return 1;
} 

/*  
 * PRF -- Length of output is in octets rather than bits
 *     since length is always a multiple of 8 output array is 
 *     organized so first N octets starting from 0 contains PRF output 
 *
 *     supported inputs are 16, 32, 48, 64
 *     output array must be 80 octets to allow for sha1 overflow
 */

void PRF(
    unsigned char *key, NSInteger key_len,
    unsigned char *prefix, NSInteger prefix_len,
    unsigned char *data, NSInteger data_len,
    unsigned char *output, NSInteger len) 
{ 
    NSInteger i;
    unsigned char input[1024]; /* concatenated input */ 
    NSInteger currentindex = 0;
    NSInteger total_len;
    
    memcpy(input, prefix, prefix_len);
    input[prefix_len] = 0; /* single octet 0 */
    memcpy(&input[prefix_len+1], data, data_len);
    total_len = prefix_len + 1 + data_len;
    input[total_len] = 0; /* single octet count, starts at 0 */
    ++total_len;
    
    for(i = 0; i < (len+19)/20; ++i) {
        hmac_sha1(input, total_len, key, key_len, &output[currentindex]);
        currentindex += 20; /* next concatenation location */
        input[total_len-1]++; /* increment octet count */
    } 
}

void generatePTK512(UInt8* ptk, UInt8* pmk, const UInt8* anonce, const UInt8* snonce, const UInt8* bssid, const UInt8* clientMAC) {
    UInt8 tmpPTK[80];
    UInt8 prefix[] = "Pairwise key expansion";
    const UInt8 *minNonce, *maxNonce;
    const UInt8 *minMAC, *maxMAC;
    UInt8 data[WPA_NONCE_LENGTH+WPA_NONCE_LENGTH+6+6];
    
    if (memcmp(anonce, snonce, WPA_NONCE_LENGTH)>0) {
        maxNonce = anonce;
        minNonce = snonce;
    } else {
        maxNonce = snonce;
        minNonce = anonce;
    }

    if (memcmp(bssid, clientMAC, 6)>0) {
        maxMAC = bssid;
        minMAC = clientMAC;
    } else {
        maxMAC = clientMAC;
        minMAC = bssid;
    }
    
    memcpy(&data[0],                        minMAC,   6);
    memcpy(&data[6],                        maxMAC,   6);
    memcpy(&data[12],                       minNonce, WPA_NONCE_LENGTH);
    memcpy(&data[12 + WPA_NONCE_LENGTH],    maxNonce, WPA_NONCE_LENGTH);
    
    PRF(pmk, 32, prefix, strlen((char *)prefix), data, WPA_NONCE_LENGTH*2 + 12, tmpPTK, 64);
    
    memcpy(ptk, tmpPTK, 64);
}

#pragma mark -

BOOL wpaTestPasswordHash() {
    unsigned char out[80];
    
    wpaPasswordHash("password", (UInt8*)"IEEE", 4, out);
    if (memcmp(out, "\xf4\x2c\x6f\xc5\x2d\xf0\xeb\xef\x9e\xbb\x4b\x90\xb3\x8a\x5f\x90\x2e\x83\xfe\x1b\x13\x5a\x70\xe2\x3a\xed\x76\x2e\x97\x10\xa1\x2e", 32)) return false;
    
    wpaPasswordHash("ThisIsAPassword", (UInt8*)"ThisIsASSID", 11, out);
    if (memcmp(out, "\x0d\xc0\xd6\xeb\x90\x55\x5e\xd6\x41\x97\x56\xb9\xa1\x5e\xc3\xe3\x20\x9b\x63\xdf\x70\x7d\xd5\x08\xd1\x45\x81\xf8\x98\x27\x21\xaf", 32)) return false;
    
    hmac_md5((UInt8*)"Hi There", 8, (UInt8*)"\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b", 16, out);
    if (memcmp(out, "\x92\x94\x72\x7a\x36\x38\xbb\x1c\x13\xf4\x8e\xf8\x15\x8b\xfc\x9d", 16))
        return false;
    
    hmac_md5((UInt8*)"what do ya want for nothing?", 28, (UInt8*)"Jefe", 4, out);
    if (memcmp(out, "\x75\x0c\x78\x3e\x6a\xb0\xb5\x03\xea\xa8\x6e\x31\x0a\x5d\xb7\x38", 16))
        return false;

    PRF((UInt8*)"\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b", 20, (UInt8*)"prefix", 6, (UInt8*)"Hi There", 8, out, 64);
    if (memcmp(out, "\xbc\xd4\xc6\x50\xb3\x0b\x96\x84\x95\x18\x29\xe0\xd7\x5f\x9d\x54\xb8\x62\x17\x5e\xd9\xf0\x06\x06\xe1\x7d\x8d\xa3\x54\x02\xff\xee\x75\xdf\x78\xc3\xd3\x1e\x0f\x88\x9f\x01\x21\x20\xc0\x86\x2b\xeb\x67\x75\x3e\x74\x39\xae\x24\x2e\xdb\x83\x73\x69\x83\x56\xcf\x5a", 64))
        return false;
    
    PRF((UInt8*)"Jefe", 4, (UInt8*)"prefix", 6, (UInt8*)"what do ya want for nothing?", 28, out, 64);
    if (memcmp(out, "\x51\xf4\xde\x5b\x33\xf2\x49\xad\xf8\x1a\xeb\x71\x3a\x3c\x20\xf4\xfe\x63\x14\x46\xfa\xbd\xfa\x58\x24\x47\x59\xae\x58\xef\x90\x09\xa9\x9a\xbf\x4e\xac\x2c\xa5\xfa\x87\xe6\x92\xc4\x40\xeb\x40\x02\x3e\x7b\xab\xb2\x06\xd6\x1d\xe7\xb9\x2f\x41\x52\x90\x92\xb8\xfc", 64))
        return false;
 
    //TODO if bored add one more check
    
    return true;
}

