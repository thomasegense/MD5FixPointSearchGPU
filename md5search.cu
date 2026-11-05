/*
 * md5search.cu - GPU search for MD5 self-matches (prefix / suffix) and
 * leading zeros, on 32-character lowercase hex strings.
 *
 * Built as a shared library and called from Java (Md5Search.java) through
 * the Java Foreign Function & Memory API. No JNI, no JCuda.
 *
 *   Windows: nvcc -O3 -arch=sm_89 -shared -o md5search.dll md5search.cu
 *            (from an "x64 Native Tools Command Prompt for VS")
 *   Linux:   nvcc -O3 -arch=sm_89 -Xcompiler -fPIC -shared -o libmd5search.so md5search.cu
 *
 * Search layout
 *   candidate = 32 hex chars = 32 bytes = MD5 message words M0..M7 (one block)
 *   M8 = 0x80 (padding), M14 = 256 (bit length), all other words 0
 *   chars  0..23 (M0..M5) : random "base", chosen by Java per kernel launch
 *   chars 24..31 (M6..M7) : "%08x" of a 32-bit counter n, enumerated on the GPU
 *   -> every launch tests exactly 2^32 candidates.
 *
 * Speed tricks
 *   - steps 0..5 depend only on the base: computed once per thread
 *   - step 6 depends only on M6: computed once per 4096 candidates
 *   - zero words and padding constants are folded into the step constants
 *   - early abort: first output word A is final after step 60, last word D
 *     after step 61; steps 62..63 run only for the ~1 in 2^32 survivors
 *   - prefix target A comes from M0,M1 (constant per launch); suffix target
 *     D is just byteswap(n)
 *
 * Self-test (CPU only, no GPU needed):
 *   Windows: cl /O2 /EHsc /TP /DMD5_CPU_TEST md5search.cu /Fe:md5test.exe && md5test.exe
 *   Linux:   g++ -O2 -x c++ -DMD5_CPU_TEST md5search.cu -o md5test && ./md5test
 */
#define _CRT_SECURE_NO_WARNINGS
#include <cstdint>
#include <cstdio>
#include <cstring>

#ifdef _WIN32
#define EXPORT extern "C" __declspec(dllexport)
#else
#define EXPORT extern "C" __attribute__((visibility("default")))
#endif

#ifdef __CUDACC__
#define HD __host__ __device__ __forceinline__
#else
#define HD static inline
#endif

/* ------------------------------------------------------------------ */
/* small helpers (GPU intrinsics on device, portable code on host)     */
/* ------------------------------------------------------------------ */
HD uint32_t rotl32(uint32_t x, int s) {
#ifdef __CUDA_ARCH__
    return __funnelshift_l(x, x, s);          /* single SHF instruction */
#else
    return (x << s) | (x >> (32 - s));
#endif
}

HD uint32_t bswap32(uint32_t x) {
#ifdef __CUDA_ARCH__
    return __byte_perm(x, 0, 0x0123);
#else
    return (x >> 24) | ((x >> 8) & 0xff00u) | ((x << 8) & 0xff0000u) | (x << 24);
#endif
}

HD int clz32(uint32_t x) {                    /* x != 0 */
#ifdef __CUDA_ARCH__
    return __clz(x);
#else
    int n = 0; while (!(x & 0x80000000u)) { x <<= 1; n++; } return n;
#endif
}

HD int ctz32(uint32_t x) {                    /* x != 0 */
#ifdef __CUDA_ARCH__
    return __ffs(x) - 1;
#else
    int n = 0; while (!(x & 1u)) { x >>= 1; n++; } return n;
#endif
}

/* 16-bit value -> 4 lowercase hex ASCII chars packed little-endian
   (first char = most significant nibble = lowest byte). Branch-free. */
HD uint32_t hex4(uint32_t x) {
    uint32_t v = ((x >> 12) & 0xFu)
               | ((x >>  8) & 0xFu) << 8
               | ((x >>  4) & 0xFu) << 16
               | ( x        & 0xFu) << 24;
    return v + 0x30303030u + (((v + 0x06060606u) >> 4) & 0x01010101u) * 39u;
}

/* Hash words in "string order": the hex string of a digest word w is the
   nibbles of bswap32(w) read from the most significant end. */
HD int prefix_count(const uint32_t h[4], const uint32_t t[4]) {
    int c = 0;
    for (int i = 0; i < 4; i++) {
        uint32_t x = bswap32(h[i] ^ t[i]);
        if (x) return c + clz32(x) / 4;
        c += 8;
    }
    return c;
}
HD int suffix_count(const uint32_t h[4], const uint32_t t[4]) {
    int c = 0;
    for (int i = 3; i >= 0; i--) {
        uint32_t x = bswap32(h[i] ^ t[i]);
        if (x) return c + ctz32(x) / 4;
        c += 8;
    }
    return c;
}
HD int zero_count(const uint32_t h[4]) {
    int c = 0;
    for (int i = 0; i < 4; i++) {
        uint32_t x = bswap32(h[i]);
        if (x) return c + clz32(x) / 4;
        c += 8;
    }
    return c;
}

/* ------------------------------------------------------------------ */
/* MD5                                                                 */
/* ------------------------------------------------------------------ */
#define IV_A 0x67452301u
#define IV_B 0xefcdab89u
#define IV_C 0x98badcfeu
#define IV_D 0x10325476u

#define F1(b, c, d) ((d) ^ ((b) & ((c) ^ (d))))
#define F2(b, c, d) ((c) ^ ((d) & ((b) ^ (c))))
#define F3(b, c, d) ((b) ^ (c) ^ (d))
#define F4(b, c, d) ((c) ^ ((b) | ~(d)))
#define STEP(F, a, b, c, d, mk, s) a = (b) + rotl32((a) + F(b, c, d) + (mk), s)

/* zero words M9..M13, M15 and the padding M8, M14 are already folded into
   the constants below (generated, do not edit by hand) */
HD void md5_steps_0_5(uint32_t& a, uint32_t& b, uint32_t& c, uint32_t& d,
                      uint32_t m0, uint32_t m1, uint32_t m2,
                      uint32_t m3, uint32_t m4, uint32_t m5) {
    STEP(F1, a, b, c, d, m0 + 0xd76aa478u, 7); /* step  0, M[0] */
    STEP(F1, d, a, b, c, m1 + 0xe8c7b756u, 12); /* step  1, M[1] */
    STEP(F1, c, d, a, b, m2 + 0x242070dbu, 17); /* step  2, M[2] */
    STEP(F1, b, c, d, a, m3 + 0xc1bdceeeu, 22); /* step  3, M[3] */
    STEP(F1, a, b, c, d, m4 + 0xf57c0fafu, 7); /* step  4, M[4] */
    STEP(F1, d, a, b, c, m5 + 0x4787c62au, 12); /* step  5, M[5] */
}
HD void md5_step_6(uint32_t& a, uint32_t& b, uint32_t& c, uint32_t& d, uint32_t m6) {
    STEP(F1, c, d, a, b, m6 + 0xa8304613u, 17); /* step  6, M[6] */
}
HD void md5_steps_7_61(uint32_t& a, uint32_t& b, uint32_t& c, uint32_t& d,
                       uint32_t m0, uint32_t m1, uint32_t m2, uint32_t m3,
                       uint32_t m4, uint32_t m5, uint32_t m6, uint32_t m7) {
    STEP(F1, b, c, d, a, m7 + 0xfd469501u, 22); /* step  7, M[7] */
    STEP(F1, a, b, c, d, 0x80u + 0x698098d8u, 7); /* step  8, M[8] */
    STEP(F1, d, a, b, c, 0x8b44f7afu, 12); /* step  9, M[9] */
    STEP(F1, c, d, a, b, 0xffff5bb1u, 17); /* step 10, M[10] */
    STEP(F1, b, c, d, a, 0x895cd7beu, 22); /* step 11, M[11] */
    STEP(F1, a, b, c, d, 0x6b901122u, 7); /* step 12, M[12] */
    STEP(F1, d, a, b, c, 0xfd987193u, 12); /* step 13, M[13] */
    STEP(F1, c, d, a, b, 0x100u + 0xa679438eu, 17); /* step 14, M[14] */
    STEP(F1, b, c, d, a, 0x49b40821u, 22); /* step 15, M[15] */
    STEP(F2, a, b, c, d, m1 + 0xf61e2562u, 5); /* step 16, M[1] */
    STEP(F2, d, a, b, c, m6 + 0xc040b340u, 9); /* step 17, M[6] */
    STEP(F2, c, d, a, b, 0x265e5a51u, 14); /* step 18, M[11] */
    STEP(F2, b, c, d, a, m0 + 0xe9b6c7aau, 20); /* step 19, M[0] */
    STEP(F2, a, b, c, d, m5 + 0xd62f105du, 5); /* step 20, M[5] */
    STEP(F2, d, a, b, c, 0x02441453u, 9); /* step 21, M[10] */
    STEP(F2, c, d, a, b, 0xd8a1e681u, 14); /* step 22, M[15] */
    STEP(F2, b, c, d, a, m4 + 0xe7d3fbc8u, 20); /* step 23, M[4] */
    STEP(F2, a, b, c, d, 0x21e1cde6u, 5); /* step 24, M[9] */
    STEP(F2, d, a, b, c, 0x100u + 0xc33707d6u, 9); /* step 25, M[14] */
    STEP(F2, c, d, a, b, m3 + 0xf4d50d87u, 14); /* step 26, M[3] */
    STEP(F2, b, c, d, a, 0x80u + 0x455a14edu, 20); /* step 27, M[8] */
    STEP(F2, a, b, c, d, 0xa9e3e905u, 5); /* step 28, M[13] */
    STEP(F2, d, a, b, c, m2 + 0xfcefa3f8u, 9); /* step 29, M[2] */
    STEP(F2, c, d, a, b, m7 + 0x676f02d9u, 14); /* step 30, M[7] */
    STEP(F2, b, c, d, a, 0x8d2a4c8au, 20); /* step 31, M[12] */
    STEP(F3, a, b, c, d, m5 + 0xfffa3942u, 4); /* step 32, M[5] */
    STEP(F3, d, a, b, c, 0x80u + 0x8771f681u, 11); /* step 33, M[8] */
    STEP(F3, c, d, a, b, 0x6d9d6122u, 16); /* step 34, M[11] */
    STEP(F3, b, c, d, a, 0x100u + 0xfde5380cu, 23); /* step 35, M[14] */
    STEP(F3, a, b, c, d, m1 + 0xa4beea44u, 4); /* step 36, M[1] */
    STEP(F3, d, a, b, c, m4 + 0x4bdecfa9u, 11); /* step 37, M[4] */
    STEP(F3, c, d, a, b, m7 + 0xf6bb4b60u, 16); /* step 38, M[7] */
    STEP(F3, b, c, d, a, 0xbebfbc70u, 23); /* step 39, M[10] */
    STEP(F3, a, b, c, d, 0x289b7ec6u, 4); /* step 40, M[13] */
    STEP(F3, d, a, b, c, m0 + 0xeaa127fau, 11); /* step 41, M[0] */
    STEP(F3, c, d, a, b, m3 + 0xd4ef3085u, 16); /* step 42, M[3] */
    STEP(F3, b, c, d, a, m6 + 0x04881d05u, 23); /* step 43, M[6] */
    STEP(F3, a, b, c, d, 0xd9d4d039u, 4); /* step 44, M[9] */
    STEP(F3, d, a, b, c, 0xe6db99e5u, 11); /* step 45, M[12] */
    STEP(F3, c, d, a, b, 0x1fa27cf8u, 16); /* step 46, M[15] */
    STEP(F3, b, c, d, a, m2 + 0xc4ac5665u, 23); /* step 47, M[2] */
    STEP(F4, a, b, c, d, m0 + 0xf4292244u, 6); /* step 48, M[0] */
    STEP(F4, d, a, b, c, m7 + 0x432aff97u, 10); /* step 49, M[7] */
    STEP(F4, c, d, a, b, 0x100u + 0xab9423a7u, 15); /* step 50, M[14] */
    STEP(F4, b, c, d, a, m5 + 0xfc93a039u, 21); /* step 51, M[5] */
    STEP(F4, a, b, c, d, 0x655b59c3u, 6); /* step 52, M[12] */
    STEP(F4, d, a, b, c, m3 + 0x8f0ccc92u, 10); /* step 53, M[3] */
    STEP(F4, c, d, a, b, 0xffeff47du, 15); /* step 54, M[10] */
    STEP(F4, b, c, d, a, m1 + 0x85845dd1u, 21); /* step 55, M[1] */
    STEP(F4, a, b, c, d, 0x80u + 0x6fa87e4fu, 6); /* step 56, M[8] */
    STEP(F4, d, a, b, c, 0xfe2ce6e0u, 10); /* step 57, M[15] */
    STEP(F4, c, d, a, b, m6 + 0xa3014314u, 15); /* step 58, M[6] */
    STEP(F4, b, c, d, a, 0x4e0811a1u, 21); /* step 59, M[13] */
    STEP(F4, a, b, c, d, m4 + 0xf7537e82u, 6); /* step 60, M[4] */
    STEP(F4, d, a, b, c, 0xbd3af235u, 10); /* step 61, M[11] */
}
HD void md5_steps_62_63(uint32_t& a, uint32_t& b, uint32_t& c, uint32_t& d,
                        uint32_t m2) {
    STEP(F4, c, d, a, b, m2 + 0x2ad7d2bbu, 15); /* step 62, M[2] */
    STEP(F4, b, c, d, a, 0xeb86d391u, 21); /* step 63, M[9] */
}

/* Parameters for one launch (2^32 candidates) */
struct Params {
    uint32_t m0, m1, m2, m3, m4, m5;  /* base: chars 0..23 */
    uint32_t tA, tB, tC;              /* hex-decoded chars 0..7, 8..15, 16..23 */
    int thrP, thrS, thrZ;             /* report if count >= threshold */
    uint32_t maskP, maskS, maskZ;     /* early-abort masks for the first 8 chars */
    int enP, enS, enZ;                /* category enabled */
};

struct Hit { uint32_t n; int p, s, z; };

/* Evaluate the survivors of the early abort exactly (rare slow path).
   Returns true if any category reaches its threshold. */
HD bool finish_candidate(const Params& P, uint32_t n,
                         uint32_t a, uint32_t b, uint32_t c, uint32_t d,
                         Hit& hit) {
    md5_steps_62_63(a, b, c, d, P.m2);
    uint32_t h[4] = { a + IV_A, b + IV_B, c + IV_C, d + IV_D };
    uint32_t t[4] = { P.tA, P.tB, P.tC, bswap32(n) };
    hit.n = n;
    hit.p = prefix_count(h, t);
    hit.s = suffix_count(h, t);
    hit.z = zero_count(h);
    return (P.enP && hit.p >= P.thrP) || (P.enS && hit.s >= P.thrS) || (P.enZ && hit.z >= P.thrZ);
}

/* host-side helpers */
HD uint32_t decode_hex_word_pair(uint32_t w0, uint32_t w1) {
    /* 8 ASCII hex chars (two little-endian words) -> digest word value */
    uint8_t ch[8];
    for (int i = 0; i < 4; i++) { ch[i] = (w0 >> (8 * i)) & 0xff; ch[4 + i] = (w1 >> (8 * i)) & 0xff; }
    uint32_t v = 0;
    for (int j = 0; j < 4; j++) {
        int hi = ch[2 * j], lo = ch[2 * j + 1];
        hi = hi <= '9' ? hi - '0' : hi - 'a' + 10;
        lo = lo <= '9' ? lo - '0' : lo - 'a' + 10;
        v |= (uint32_t)((hi << 4) | lo) << (8 * j);
    }
    return v;
}

HD uint32_t mask_first(int k) {   /* first k (1..8) chars of a word */
    if (k >= 8) return 0xffffffffu;
    return bswap32(0xffffffffu << (32 - 4 * k));
}
HD uint32_t mask_last(int k) {    /* last k (1..8) chars of a word */
    if (k >= 8) return 0xffffffffu;
    return bswap32((1u << (4 * k)) - 1u);
}

/* One candidate: steps 7..61, early abort, exact check of survivors.
   Shared by the GPU kernel and the CPU self-test. */
HD bool check_candidate(const Params& P, uint32_t a6, uint32_t b6, uint32_t c6, uint32_t d6,
                        uint32_t m6, uint32_t n, Hit& hit) {
    const uint32_t m7 = hex4(n & 0xFFFFu);
    uint32_t a = a6, b = b6, c = c6, d = d6;
    md5_steps_7_61(a, b, c, d, P.m0, P.m1, P.m2, P.m3, P.m4, P.m5, m6, m7);
    const uint32_t A = a + IV_A;                   /* final word A (after step 60) */
    const uint32_t D = d + IV_D;                   /* final word D (after step 61) */
    const bool cand = (P.enP && ((A ^ P.tA) & P.maskP) == 0)
                    | (P.enZ && (A & P.maskZ) == 0)
                    | (P.enS && ((D ^ bswap32(n)) & P.maskS) == 0);
    if (!cand) return false;                       /* ~all candidates exit here */
    return finish_candidate(P, n, a, b, c, d, hit);
}

/* Fill launch parameters from the 6 base words and thresholds (<=0 disables) */
HD void make_params(Params& P, const uint32_t* base, int thrP, int thrS, int thrZ) {
    P.m0 = base[0]; P.m1 = base[1]; P.m2 = base[2]; P.m3 = base[3]; P.m4 = base[4]; P.m5 = base[5];
    P.tA = decode_hex_word_pair(P.m0, P.m1);
    P.tB = decode_hex_word_pair(P.m2, P.m3);
    P.tC = decode_hex_word_pair(P.m4, P.m5);
    P.enP = thrP > 0; P.enS = thrS > 0; P.enZ = thrZ > 0;
    P.thrP = thrP; P.thrS = thrS; P.thrZ = thrZ;
    P.maskP = mask_first(thrP > 0 ? thrP : 1);
    P.maskS = mask_last (thrS > 0 ? thrS : 1);
    P.maskZ = mask_first(thrZ > 0 ? thrZ : 1);
}

#define ITEMS        (1u << 20)   /* work items per launch          */
#define ITEM_SIZE    4096u        /* candidates per work item       */
#define BLOCK_THREADS 1024        /* threads per block (one per SM) */

#ifdef __CUDACC__
/* ------------------------------------------------------------------ */
/* GPU kernel                                                          */
/* ------------------------------------------------------------------ */
__global__ void __launch_bounds__(BLOCK_THREADS)
md5_kernel(Params P, unsigned int* hitCount, Hit* hits, int maxHits) {
    uint32_t a0 = IV_A, b0 = IV_B, c0 = IV_C, d0 = IV_D;
    md5_steps_0_5(a0, b0, c0, d0, P.m0, P.m1, P.m2, P.m3, P.m4, P.m5);

    const uint32_t stride = gridDim.x * blockDim.x;
    for (uint32_t item = blockIdx.x * blockDim.x + threadIdx.x; item < ITEMS; item += stride) {
        const uint32_t nHi = item * ITEM_SIZE;            /* low 12 bits zero */
        const uint32_t m6  = hex4(nHi >> 16);
        uint32_t a6 = a0, b6 = b0, c6 = c0, d6 = d0;
        md5_step_6(a6, b6, c6, d6, m6);

        for (uint32_t j = 0; j < ITEM_SIZE; j++) {
            Hit hit;
            if (check_candidate(P, a6, b6, c6, d6, m6, nHi | j, hit)) {
                unsigned int idx = atomicAdd(hitCount, 1u);
                if (idx < (unsigned int)maxHits) hits[idx] = hit;
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* C API for Java                                                      */
/* ------------------------------------------------------------------ */
static int           g_blocks   = 0;
static unsigned int* g_dCount   = nullptr;
static Hit*          g_dHits    = nullptr;
static const int     MAX_HITS   = 4096;

/* Returns number of blocks used, or negative CUDA error code.
   info receives a human readable description of the device. */
EXPORT int md5_init(int device, int loadPercent, char* info, int infoLen) {
    cudaError_t e = cudaSetDevice(device);
    if (e != cudaSuccess) { snprintf(info, infoLen, "cudaSetDevice: %s", cudaGetErrorString(e)); return -(int)e; }
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, device);
    if (loadPercent < 1)   loadPercent = 1;
    if (loadPercent > 100) loadPercent = 100;
    /* one 1024-thread block fits per SM; the block scheduler places blocks
       on idle SMs first, so blocks = SMs * load% keeps the rest idle */
    g_blocks = (prop.multiProcessorCount * loadPercent + 50) / 100;
    if (g_blocks < 1) g_blocks = 1;
    if ((e = cudaMalloc(&g_dCount, sizeof(unsigned int))) != cudaSuccess ||
        (e = cudaMalloc(&g_dHits, MAX_HITS * sizeof(Hit))) != cudaSuccess) {
        snprintf(info, infoLen, "cudaMalloc: %s", cudaGetErrorString(e)); return -(int)e;
    }
    snprintf(info, infoLen, "%s, %d SMs, using %d blocks x %d threads = %d GPU threads (%d%% of SMs)",
             prop.name, prop.multiProcessorCount, g_blocks, BLOCK_THREADS,
             g_blocks * BLOCK_THREADS, loadPercent);
    return g_blocks;
}

/* Test the 2^32 candidates <base(24 chars)><%08x n>.
   base: 6 words (chars 0..23, little-endian ASCII).
   thresholds: report a candidate if any count >= its threshold (<=0 disables).
   out: maxOut entries of 4 ints {n, prefix, suffix, zeros}.
   Returns total number of hits (may exceed maxOut), or negative error. */
EXPORT int md5_search(const uint32_t* base, int thrP, int thrS, int thrZ, int32_t* out, int maxOut) {
    Params P;
    make_params(P, base, thrP, thrS, thrZ);

    cudaMemset(g_dCount, 0, sizeof(unsigned int));
    md5_kernel<<<g_blocks, BLOCK_THREADS>>>(P, g_dCount, g_dHits, MAX_HITS);
    cudaError_t e = cudaDeviceSynchronize();
    if (e == cudaSuccess) e = cudaGetLastError();
    if (e != cudaSuccess) return -(int)e;

    unsigned int count = 0;
    cudaMemcpy(&count, g_dCount, sizeof(count), cudaMemcpyDeviceToHost);
    int n = (int)count < MAX_HITS ? (int)count : MAX_HITS;
    if (n > maxOut) n = maxOut;
    if (n > 0) {
        Hit tmp[MAX_HITS];
        cudaMemcpy(tmp, g_dHits, n * sizeof(Hit), cudaMemcpyDeviceToHost);
        for (int i = 0; i < n; i++) {
            out[4 * i]     = (int32_t)tmp[i].n;
            out[4 * i + 1] = tmp[i].p;
            out[4 * i + 2] = tmp[i].s;
            out[4 * i + 3] = tmp[i].z;
        }
    }
    return (int)count;
}

EXPORT void md5_shutdown() {
    cudaFree(g_dHits);  g_dHits  = nullptr;
    cudaFree(g_dCount); g_dCount = nullptr;
}
#endif /* __CUDACC__ */

#ifdef MD5_CPU_TEST
/* ------------------------------------------------------------------ */
/* CPU self-test of the step code, counters and masks (no GPU needed)  */
/* ------------------------------------------------------------------ */
static uint32_t word_of(const char* s) {
    return (uint32_t)(uint8_t)s[0] | (uint32_t)(uint8_t)s[1] << 8 |
           (uint32_t)(uint8_t)s[2] << 16 | (uint32_t)(uint8_t)s[3] << 24;
}
static void digest_hex(const char* s32, char out[33], int counts[3]) {
    uint32_t m[8];
    for (int i = 0; i < 8; i++) m[i] = word_of(s32 + 4 * i);
    uint32_t a = IV_A, b = IV_B, c = IV_C, d = IV_D;
    md5_steps_0_5(a, b, c, d, m[0], m[1], m[2], m[3], m[4], m[5]);
    md5_step_6(a, b, c, d, m[6]);
    md5_steps_7_61(a, b, c, d, m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7]);
    md5_steps_62_63(a, b, c, d, m[2]);
    uint32_t h[4] = { a + IV_A, b + IV_B, c + IV_C, d + IV_D };
    for (int i = 0; i < 16; i++) sprintf(out + 2 * i, "%02x", (h[i / 4] >> (8 * (i % 4))) & 0xff);
    uint32_t t[4];
    for (int i = 0; i < 4; i++) {
        char tmp[9]; memcpy(tmp, s32 + 8 * i, 8); tmp[8] = 0;
        uint32_t v; sscanf(tmp, "%x", &v); t[i] = bswap32(v);
    }
    counts[0] = prefix_count(h, t); counts[1] = suffix_count(h, t); counts[2] = zero_count(h);
}

/* Emulate the kernel for one base over counters [n0, n0+cnt) with the given
   thresholds; compare every candidate against the full reference digest so
   that the early-abort filter can never silently drop a valid hit. */
static int emulate(const char* base24, uint32_t n0, uint32_t cnt, int tp, int ts, int tz) {
    uint32_t base[6];
    for (int i = 0; i < 6; i++) base[i] = word_of(base24 + 4 * i);
    Params P; make_params(P, base, tp, ts, tz);
    uint32_t a0 = IV_A, b0 = IV_B, c0 = IV_C, d0 = IV_D;
    md5_steps_0_5(a0, b0, c0, d0, P.m0, P.m1, P.m2, P.m3, P.m4, P.m5);
    int hits = 0, errors = 0;
    for (uint32_t n = n0; n != n0 + cnt; n++) {
        uint32_t m6 = hex4(n >> 16);
        uint32_t a = a0, b = b0, c = c0, d = d0;
        md5_step_6(a, b, c, d, m6);
        Hit hit;
        bool got = check_candidate(P, a, b, c, d, m6, n, hit);
        char s[33], hx[33]; int ref[3];
        sprintf(s, "%s%08x", base24, n);
        digest_hex(s, hx, ref);
        bool want = (tp > 0 && ref[0] >= tp) || (ts > 0 && ref[1] >= ts) || (tz > 0 && ref[2] >= tz);
        if (got != want || (got && (hit.p != ref[0] || hit.s != ref[1] || hit.z != ref[2]))) {
            errors++;
            if (errors < 5) printf("MISMATCH %s got=%d want=%d\n", s, got, want);
        }
        if (got) {
            hits++;
            if (tp >= 9 || ts >= 9) printf("  hit %s -> %s p=%d s=%d z=%d\n", s, hx, hit.p, hit.s, hit.z);
        }
    }
    printf("emulate %s n=%08x+%u thr=(%d,%d,%d): %d hits, %d errors\n", base24, n0, cnt, tp, ts, tz, hits, errors);
    return errors;
}
int main(int argc, char** argv) {
    for (int i = 1; i < argc; i++) {
        char hx[33]; int c[3];
        digest_hex(argv[i], hx, c);
        printf("%s %s prefix=%d suffix=%d zeros=%d\n", argv[i], hx, c[0], c[1], c[2]);
    }
    /* hex4 must equal sprintf("%04x") */
    for (uint32_t x = 0; x < 65536; x++) {
        char tmp[5]; sprintf(tmp, "%04x", x);
        if (hex4(x) != word_of(tmp)) { printf("hex4 FAIL at %u\n", x); return 1; }
    }
    printf("hex4 OK\n");
    int err = 0;
    /* low thresholds: many hits, exercises masks of every length 1..8 */
    for (int k = 1; k <= 8; k++) {
        err += emulate("0123456789abcdef01234567", 0x12340000u, 200000, k, 0, 0);
        err += emulate("0123456789abcdef01234567", 0x12340000u, 200000, 0, k, 0);
        err += emulate("0123456789abcdef01234567", 0x12340000u, 200000, 0, 0, k);
    }
    err += emulate("0123456789abcdef01234567", 0xfffe0000u, 300000, 2, 2, 2); /* wraps n */
    /* the two known 12-character finds must be found by the search path */
    err += emulate("54db1011d76dc70a0a9df3ff", 0x3e0b0000u, 65536, 12, 0, 0);
    err += emulate("df12c1434cec7850a7900ce0", 0x27af0000u, 65536, 0, 12, 0);
    printf(err ? "SELFTEST FAILED\n" : "SELFTEST OK\n");
    return err != 0;
}
#endif
