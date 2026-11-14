# Md5Search – GPU search for MD5 self-matches

Md5Search searches 32-character lowercase hex strings for three kinds of records:

- **Prefix match** – the MD5 starts with the same characters as the input
- **Suffix match** – the MD5 ends with the same characters as the input
- **Leading zeros** – the MD5 starts with as many `0` characters as possible

Example of a 14-character prefix match:

```
input  aa265d3803aaea5a6ac6044540ca8b59
md5    aa265d3803aaea02261baeca7cb8068c 
       ^^^^^^^^^^^^
```

It was written for the MD5 challenge at
[solveathome.org/projects/md5](https://solveathome.org/projects/md5),
which keeps records for MD5 self-matches and for the most leading zeros.

The search runs on an NVIDIA GPU using CUDA. A Java program controls it,
checks every hit again with Java's own MD5 and logs new best results.
It runs on Windows and Linux. Several machines can search at the same time:
each one picks random starting points from 2^96 possibilities, so they never
repeat each other's work.

## Get the code

```
git clone https://github.com/thomasegense/MD5FixPointSearchGPU.git
cd MD5FixPointSearchGPU
```

Or download it as a zip: **Code → Download ZIP** on the GitHub page.

## Best results found with this program

| Category | Characters | Input | MD5 |
|---|---|---|---|
| Suffix match | 13 | `2c1952edef05b82a94a77102ca4e0c57` | `ffc06efdc60838c438f77102ca4e0c57` |

## Files

| File | Purpose |
|---|---|
| `md5search.cu` | CUDA search code. Compiled to `md5search.dll` (Windows) or `libmd5search.so` (Linux) |
| `Md5Search.java` | Java host program. Needs Java 22 or newer |
| `build.bat` | Windows: builds everything and starts the search |
| `build.sh` | Linux: builds everything and starts the search |
| `md5search.log` | Log of all results. Created automatically |
| `md5search-best.properties` | Saved best values. Created automatically |
| `LICENSE` | MIT License |

## Requirements

- An NVIDIA GPU with a current driver (`nvidia-smi` must work)
- The CUDA Toolkit (`nvcc`)
- A C++ compiler: Visual Studio Build Tools on Windows, `g++` on Linux
- Java 22 or newer. It does not need to be your default Java

---

# Windows

## W1. Install the software (only once)

### Visual Studio 2022 Build Tools (C++ compiler for nvcc)

1. Open **Terminal (Admin)**: right-click the Start button.
2. Run:
   ```
   winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
   ```
3. Wait until the installer window closes, then restart Windows.

Alternative: download "Build Tools for Visual Studio 2022" from
visualstudio.microsoft.com/downloads and tick **Desktop development with C++**.

**Check:** open **x64 Native Tools Command Prompt for VS 2022** from the
Start menu and type `cl`. It must print `Microsoft (R) C/C++ Optimizing
Compiler ... for x64`.

- `cl` only works in that prompt, not in a normal cmd or PowerShell window.
- Use the **x64** prompt. With the 32-bit prompt, nvcc fails with
  "Host compiler targets unsupported OS".

### CUDA Toolkit

1. Close all command prompts.
2. Download from developer.nvidia.com/cuda-downloads:
   **Windows → x86_64 → 11 → exe (local)**.
3. Install with **Express**, then restart Windows.

**Check:** in the x64 Native Tools prompt, `nvcc --version` shows the CUDA
release, and `nvidia-smi` shows your GPU.

The toolkit may be slightly newer than the CUDA version shown by `nvidia-smi`.
Within the same major version (e.g. 13.x) this works. If the program reports
"driver version is insufficient", update the GPU driver.

### Java 22 or newer, without changing your default Java

1. Download the **.zip** (not the .msi) of a JDK 22 or newer, e.g. from adoptium.net.
   The .msi installer can change your PATH and JAVA_HOME; the zip changes nothing.
2. Unpack it, for example to `C:\java\jdk-26`.
3. **Check:** `"C:\java\jdk-26\bin\java" -version` shows the new version.

## W2. Build and start (first time, and after changing md5search.cu)

1. Open **x64 Native Tools Command Prompt for VS 2022**.
2. Go to the folder with the files, tell the script which Java to use, and build:
   ```
   cd /d C:\path\to\MD5FixPointSearchGPU
   set JAVA=C:\java\jdk-26\bin\java.exe
   set LOAD=100
   build.bat
   ```
   Leave out `set JAVA=...` if `java -version` already shows 22 or newer.

`build.bat` does three things:

1. Runs a CPU self-test of the MD5 code. It must end with `SELFTEST OK`.
2. Builds `md5search.dll` for the installed GPU (`-arch=native`).
3. Starts the search.

If Java reports errors about `java.lang.foreign` while compiling `Md5Search.java`,
the Java version is older than 22.

## W3. Start the search (when the DLL is already built)

Any command prompt works:
```
cd /d C:\path\to\MD5FixPointSearchGPU
C:\java\jdk-26\bin\java -Dmd5.load=100 --enable-native-access=ALL-UNNAMED Md5Search.java
```

## W4. Power limit (recommended, see "Power limit and load" below)

Open a Command Prompt or PowerShell **as Administrator**, for example:
```
nvidia-smi -pl 250
```
The limit resets when Windows restarts, so run it again after every restart.
MSI Afterburner's *Power Limit* slider can make it permanent.

## W5. Windows notes

- **Sleep:** Settings → System → Power → never sleep when plugged in.
- **GPU watchdog (TDR):** Windows resets the driver if one GPU launch takes
  longer than about 2 seconds on a GPU that drives a display. A launch tests
  2^32 candidates, so this only matters on slow GPUs or with a very low load
  setting. If it happens, raise `md5.load`.
- If the GPU also drives your screen, high load can make the desktop lag a little.

---

# Linux (Ubuntu)

## L1. Install the software (only once)

### Java 22 or newer, without changing your default Java

```
sudo apt update && sudo apt install -y openjdk-25-jdk
```

**Check:**
```
/usr/lib/jvm/java-25-openjdk-amd64/bin/java -version
```

Ubuntu may make the newest JDK your default Java. Switch the default back with
`sudo update-alternatives --config java` if other programs need an older one.
If the default is already set by hand ("manual mode"), it is not changed.

If apt cannot find the package, run `sudo add-apt-repository universe` first.

### CUDA Toolkit

First check whether it is already installed:
```
ls -d /usr/local/cuda*/bin/nvcc
```

- **Found:** nothing to install. `build.sh` finds `/usr/local/cuda/bin/nvcc`
  by itself. To use `nvcc` directly as well:
  ```
  echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc && source ~/.bashrc
  ```
- **Not found:** install a toolkit version your driver supports. The
  "CUDA Version" in the top right of `nvidia-smi` is the newest it supports.
  Example for CUDA 13.0 on Ubuntu 24.04 (use `ubuntu2204` on 22.04):
  ```
  wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
  sudo dpkg -i cuda-keyring_1.1-1_all.deb
  sudo apt update
  sudo apt install -y cuda-toolkit-13-0
  ```
  Install `cuda-toolkit-…` only, not `cuda` or `cuda-drivers`, because
  those can replace your graphics driver.

### g++-12 (only for CUDA 12.3 and older)

CUDA 12.3 and older reject GCC 13 (the default on Ubuntu 24.04) with
"unsupported GNU version! gcc versions later than 12 are not supported".
Install GCC 12 next to it (your default GCC is not changed):
```
sudo apt install -y g++-12
```

## L2. Build and start (first time, and after changing md5search.cu)

```
cd /path/to/MD5FixPointSearchGPU
chmod +x build.sh
LOAD=100 JAVA=/usr/lib/jvm/java-25-openjdk-amd64/bin/java ./build.sh
```

With CUDA 12.3 or older, add `CCBIN=g++-12` in front.

`build.sh` does four things:

1. Checks that the Java version is 22 or newer.
2. Runs the CPU self-test. It must end with `SELFTEST OK`.
3. Builds `libmd5search.so` for the installed GPU (`-arch=native`).
4. Starts the search.

Settings for `build.sh`:

| Variable | Meaning |
|---|---|
| `JAVA=...` | Java 22+ to use (default: `java`) |
| `LOAD=100` | GPU load in percent (default: 50) |
| `CCBIN=g++-12` | Host compiler for nvcc. Without it, `build.sh` tries the default GCC first and then retries with an older `g++` if installed, which prints harmless error messages |

## L3. Start the search (when the library is already built)

```
cd /path/to/MD5FixPointSearchGPU
/usr/lib/jvm/java-25-openjdk-amd64/bin/java -Dmd5.load=100 --enable-native-access=ALL-UNNAMED Md5Search.java
```

To keep it running after logging out, use `nohup` (or `screen`/`tmux`):
```
nohup /usr/lib/jvm/java-25-openjdk-amd64/bin/java -Dmd5.load=100 --enable-native-access=ALL-UNNAMED Md5Search.java > console.out 2>&1 &
```
Stop it with `kill <pid>`, not `kill -9`, so the current GPU launch can finish.

## L4. Power limit (recommended, see "Power limit and load" below)

Check the allowed range of your GPU:
```
nvidia-smi -q -d POWER | grep -i "power limit"
```
Then set a limit, for example:
```
sudo nvidia-smi -pm 1
sudo nvidia-smi -pl 250
```
The limit resets at reboot, so run it again after every reboot.

---

# Both systems

## Power limit and load

GPU default power limits are tuned for short bursts of maximum speed, as in
games and benchmarks, not for days of continuous work. The last few percent
of speed cost a lot of power, heat and fan noise. For long runs:
**lower the power limit and run at 100% load.**

Example, RTX 4090 (default limit 450 W):

| Setting | Speed | Power |
|---|---|---|
| 80% load, 450 W | about 73 GH/s | 399 W |
| **100% load, 250 W** | **86.6 GH/s** | 250 W |

That is about 19% more speed for about 37% less power, with lower
temperature and fan speed. When a card already sits at its power limit,
a higher load setting costs no extra heat: all SMs share the same watts at a
lower clock, which is more efficient.

How to find a good setting for your GPU:

1. Set a power limit around 55–75% of the default (not below the "Min Power Limit").
2. Run at 100% load for 10 minutes.
3. Compare speed, temperature and fan speed (see "Monitoring the GPU").

`md5.load` alone is a poor way to reduce heat: the card often still runs at
its power limit, just slower.

Keep the GPU at or below about 85 °C for long runs, and keep the case and
fans free of dust.

## Stopping

Press **Ctrl+C**. The program lets the current GPU launch finish, saves and
exits. The best values are kept in the save file.

## Self-test at start

At every start the program searches for two known 12-character results:

- prefix: `54db1011d76dc70a0a9df3ff3e0b390f` → `54db1011d76d137956603122ad86d762`
- suffix: `df12c1434cec7850a7900ce027af4b78` → `b2f6053087022898fe920ce027af4b78`

If it does not find both, it stops. A broken build can never run unnoticed.
The self-test also prints the measured speed.

## Settings (`-D` options for Java)

| Option | Default | Meaning |
|---|---|---|
| `-Dmd5.load=100` | 50 | Percentage of the GPU's SMs to use (sets the number of GPU threads) |
| `-Dmd5.minReport=10` | 10 | Never log results shorter than this |
| `-Dmd5.startPrefix=12` | 12 | Starting best value if no save file exists |
| `-Dmd5.startSuffix=12` | 12 | Same for suffix |
| `-Dmd5.startZeros=12` | 12 | Same for leading zeros |
| `-Dmd5.progressMs=60000` | 60000 | How often (ms) a progress line is printed |
| `-Dmd5.device=0` | 0 | Which GPU to use |
| `-Dmd5.lib=...` | `md5search.dll` / `libmd5search.so` | Path to the CUDA library |

The progress line shows the average speed since the start. For the current
speed, take two progress lines one minute apart:
(difference in candidates) ÷ 60 s.

To test that logging works, start with low values, e.g.
`-Dmd5.startPrefix=10 -Dmd5.startSuffix=10 -Dmd5.startZeros=10`
(only takes effect when no save file exists). On a fast GPU,
10-character results appear within seconds.

## What `--enable-native-access=ALL-UNNAMED` means

Java calls the CUDA library through the *Foreign Function & Memory API*
(final since Java 22). Native calls can crash the JVM, so Java requires
explicit permission:

- `--enable-native-access` grants the permission.
- `ALL-UNNAMED` says which code gets it: all code that is not in a named
  Java module. A single-file program like `Md5Search.java` lives in this
  "unnamed module".

Without the flag, Java prints a warning. Later versions are expected to refuse.

## The save file: `md5search-best.properties`

It remembers the best result in each category, so a restart continues where
it stopped. Example:

```
#Md5Search best values
prefix.best=12
prefix.input=<32 hex characters>
prefix.md5=<its MD5>
suffix.best=13
suffix.input=<32 hex characters>
suffix.md5=<its MD5>
zeros.best=11
zeros.input=<32 hex characters>
zeros.md5=<its MD5>
```

For each category:

- `*.best` – the number of matching characters (or leading zeros)
- `*.input` – the 32-character input that gave it
- `*.md5` – its MD5, so you can check it by hand

How the program uses it:

- **At start** it reads the file. Its values override the `-Dmd5.start…`
  settings. Without the file, the start values are used.
- **On a new best result** it writes the whole file again (first to a
  temporary file, then replacing the old one, so a crash cannot corrupt it).
- **Ties are not saved**, only logged.
- The GPU only reports results **at least as good as the current best**
  (and at least `md5.minReport`). So this file decides what gets logged.

What you can do with it:

- **Reset everything:** stop the program and delete the file.
- **Change a level:** stop the program, edit `prefix.best`, `suffix.best` or
  `zeros.best`, and start again. E.g. set all three to 13 to log only
  results that tie or beat 13.

Each machine keeps its own save file and log. `md5search.log` keeps all
results, including ties, with date and time, and is never overwritten.

## Log examples

```
NEW BEST prefix match  12 chars (previous 11): <input> -> <md5>   [after 5.583e+10 candidates]
TIE      leading zeros 12 chars:               <input> -> <md5>   [after 6.442e+11 candidates]
1.091e+12 candidates, 18.1 GH/s (18.1 GH/s overall), running 60s | expected time to beat: prefix 13=2.9d suffix 13=2.9d zeros 13=2.9d
```

## How the search works

- Java picks **24 random hex characters** (the "base").
- The GPU tests all **2^32 endings** `00000000`–`ffffffff` of that base:
  about 4.3 billion inputs per launch (about 0.05 s on an RTX 4090).
- The MD5 work for the 24 fixed characters is shared by all candidates.
- After step 61 of 64, the first and last 8 hex characters of the MD5 are
  known. Prefix, zeros and suffix are checked **at the same time**. Almost all
  candidates fail and are dropped.
- The rare survivors get the full MD5 and an exact count. Java checks each
  reported hit again with `MessageDigest` before logging it.

## Monitoring the GPU

Print temperature, power, fan and clock every 5 seconds (Ctrl+C to stop):
```
nvidia-smi --query-gpu=temperature.gpu,power.draw,fan.speed,clocks.sm --format=csv -l 5
```

## Expected times

A k-character result is a 1 in 16^k event per category, so each extra
character takes 16 times longer. Example for an RTX 4090 at 86.6 GH/s:

| Target | Candidates (average) | Expected time per category |
|---|---|---|
| 10 characters | 1.1 × 10^12 | about 13 seconds |
| 11 characters | 1.8 × 10^13 | about 3.4 minutes |
| 12 characters | 2.8 × 10^14 | about 1 hour |
| 13 characters | 4.5 × 10^15 | about 14 hours |
| 14 characters | 7.2 × 10^16 | about 9.6 days |
| 15 characters | 1.2 × 10^18 | about 5 months |

For another GPU, scale by its speed (shown by the self-test and the progress
line). The progress line also shows the expected time to beat each current best.

It is a lottery: each candidate has the same chance, the search has no memory,
and the real time can be much shorter or longer than the average. The chance of
at least one hit after running t times the expected time is 1 − e^(−t):
about 63% after the expected time, 86% after twice and 95% after three times.

## Checklist

- [ ] After every reboot, set the power limit again
- [ ] Windows: never sleep when plugged in
- [ ] Check the GPU temperature now and then (at or below about 85 °C)
- [ ] Before submitting a record, verify it independently, e.g. in Python:
      `python3 -c "import hashlib; print(hashlib.md5(b'<input>').hexdigest())"`

## License

MIT License. See `LICENSE`.
