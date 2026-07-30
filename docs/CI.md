# CI/CD Pipeline — Mali GPU Acceleration Packages

## Visión General

Este repositorio tiene scripts de CI listos para GitHub Actions que compilan desde source los paquetes necesarios para aceleración gráfica Mali en Termux. Los scripts están en `ci/` y el workflow `.github/workflows/build-packages.yml` está **en desarrollo** (el directorio `.github/workflows/` existe pero el workflow aún no se ha creado).

Una vez activo, el pipeline producirá artefactos `.pkg.tar.xz` listos para instalar con `pacman -U` directamente en Termux.

## Workflow (planeado): `build-packages.yml`

| Campo | Valor |
|-------|-------|
| **Trigger** | `workflow_dispatch` (manual) o semanal (lunes 6:00 UTC) |
| **Runner** | `ubuntu-latest` |
| **Artefactos** | 3 paquetes `.pkg.tar.xz` + GitHub Release |

### Jobs

#### 1. `build-virglrenderer`

| Detalle | Descripción |
|---------|-------------|
| **Qué hace** | Compila virglrenderer desde source (freedesktop.org, versión 1.3.0) |
| **Cómo** | Meson cross-compile con Android NDK r27 para `aarch64-linux-android` |
| **Dependencias** | libdrm, libepoxy, libglvnd, libx11, mesa (extraídos de Termux repo como sysroot) |
| **Duración** | ~3 minutos |
| **Output** | `virglrenderer-1.3.0-1-aarch64.pkg.tar.xz` |
| **Script** | `ci/build-virglrenderer.sh` |

#### 2. `build-angle`

| Detalle | Descripción |
|---------|-------------|
| **Qué hace** | Compila Google ANGLE desde source (chromium.googlesource.com/angle/angle) |
| **Cómo** | `depot_tools` (gclient sync) + GN + Ninja cross-compile con NDK r27 |
| **Variantes** | 3 backends (`gl`, `vulkan`, `vulkan-null`) → `$PREFIX/opt/angle-android/{variant}/` |
| **Duración** | 30-60 min (primera vez, incluye ~1-2 GB de source download) |
| **Caching** | `depot_tools` y ANGLE source cacheados entre runs |
| **Output** | `angle-android-2.1.<commit-count>-<commit-hash>-aarch64.pkg.tar.xz` |
| **Script** | `ci/build-angle.sh` |

#### 3. `build-icd-wrapper`

| Detalle | Descripción |
|---------|-------------|
| **Qué hace** | Genera el JSON ICD wrapper para que ANGLE encuentre el driver Vulkan de Mali |
| **Cómo** | Script bash que detecta la ruta del driver Mali (`vulkan.mali.so` o `libGLES_mali.so`) y crea el ICD JSON |
| **Duración** | ~5 segundos |
| **Output** | `mesa-vulkan-icd-wrapper-25.0.0-1-aarch64.pkg.tar.xz` |
| **Script** | `ci/build-icd.sh` |

#### 4. `create-release`

| Detalle | Descripción |
|---------|-------------|
| **Qué hace** | Crea un GitHub Release con los 3 `.pkg.tar.xz` como assets |
| **Tag** | `ci-build-YYYYMMDD-HHMMSS` |
| **Depende de** | Los 3 jobs anteriores |

### Arquitectura del Build

```
ubuntu-latest runner
  ├── Android NDK r27 (setup-ndk action)
  │
  ├── virglrenderer
  │   ├── Source: gitlab.freedesktop.org (tarball)
  │   ├── Cross-file: ci/aarch64-linux-android-cross.ini
  │   ├── Sysroot: Termux .debs extraídos via ci/setup-sysroot.sh
  │   └── Build: ci/build-virglrenderer.sh
  │
  ├── ANGLE
  │   ├── Source: chromium.googlesource.com (gclient sync)
  │   ├── Build: depot_tools + GN + Ninja
  │   ├── Commit pinneado en workflow (ANGLE_COMMIT)
  │   └── Script: ci/build-angle.sh
  │
  └── ICD Wrapper
      ├── Source: generado (no descarga externa)
      └── Script: ci/build-icd.sh
```

### Scripts en `ci/`

| Script | Propósito |
|--------|-----------|
| `setup-sysroot.sh` | Descarga Termux `.debs` dinámicamente desde `Packages.gz` del repo Termux |
| `aarch64-linux-android-cross.ini` | Cross-file de meson para NDK `aarch64-linux-android21` |
| `build-virglrenderer.sh` | Cross-compile virglrenderer con meson + ninja |
| `build-angle.sh` | Cross-compile ANGLE con GN + Ninja para 3 backends |
| `build-icd.sh` | Genera el ICD JSON wrapper para Mali Vulkan |

### Errores Conocidos y Soluciones

| Error | Causa | Solución |
|-------|-------|----------|
| `SIGPIPE` / `exit code 141` | `set -eo pipefail` con `zcat \| awk ... exit` | `set +o pipefail` temporal o `\|\| true` |
| `undefined constant 'gnu11'` | Meson cross-file sin quotes alrededor del valor | Usar `'gnu11'` con comillas |
| `fatal error: 'log/log.h'` | NDK r27 eliminó Android logging headers | Stub header generado automáticamente (`ci/build-virglrenderer.sh`) |
| `fatal error: 'cutils/properties.h'` | NDK r27 eliminó property headers | Stub header generado automáticamente |
| `unknown type 'pthread_barrier_t'` | NDK r27 eliminó `pthread_barrier` | Implementación compat inline generada automáticamente |
| `gbm.h not found` | Dual sysroot (NDK + Termux) no configurado correctamente | Flags: `--sysroot=$NDK_SYSROOT -isystem $SYSROOT/.../include` |
| `undefined @LIBC symbols` | Termux `.so` vs NDK bionic mismatch | `meson -Db_lundef=false` |
| `AngleLibraries.apk not found` | Estructura de output de ANGLE cambió | Fallback: busca `.so` directamente en build dir |
| `pkg-config cannot find epoxy` | Sysroot incompleto o `.pc` no indexados | Verificar `PKG_CONFIG_LIBDIR` y `PKG_CONFIG_SYSROOT_DIR` |

### Estado Actual

| Componente | Estado |
|------------|--------|
| Scripts de build (`ci/`) | ✅ Completos y funcionales |
| Cross-file meson | ✅ Listo |
| Workflow GitHub Actions | 🔧 En desarrollo (`.github/workflows/` vacío) |
| GitHub Releases automáticos | 🔧 Pendiente del workflow |
| Caching de ANGLE source | 🔧 Pendiente de configurar en workflow |

## Cómo Usar los Artefactos (cuando estén disponibles)

### Manualmente desde GitHub Releases

```bash
# Ir a https://github.com/Leonisaurov/MaliAcceleration/releases
# Descargar los .pkg.tar.xz más recientes
pacman -U *.pkg.tar.xz
```

### Build local (sin CI)

Los scripts en `ci/` están diseñados para GitHub Actions, pero pueden ejecutarse localmente
en una máquina Linux con Android NDK r27 instalado:

```bash
export NDK_DIR=/path/to/android-ndk-r27
export SYSROOT_DIR=./sysroot

# 1. Preparar sysroot
./ci/setup-sysroot.sh "$SYSROOT_DIR"

# 2. Build virglrenderer
./ci/build-virglrenderer.sh

# 3. Build ANGLE (requiere depot_tools en PATH)
./ci/build-angle.sh

# 4. Build ICD wrapper
./ci/build-icd.sh
```

> **Nota**: ANGLE requiere `depot_tools` (gclient, gn, ninja) y ~2 GB de descarga
> de source. No es práctico para builds on-device en Termux.
