#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Forza un re-enumerate USB sui dispositivi Apple «iPod» ancora collegati.
/// Dopo `diskutil eject` non resta un disco da montare: senza questo lo iPod
/// resta in carica e VintageTunes non lo vede finché non si stacca il cavo.
/// @return numero di dispositivi su cui ReEnumerate ha avuto successo.
int VTReenumerateConnectediPods(void);

#ifdef __cplusplus
}
#endif
