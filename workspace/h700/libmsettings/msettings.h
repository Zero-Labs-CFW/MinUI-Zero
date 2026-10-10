#ifndef __msettings_h__
#define __msettings_h__

void InitSettings(void);
void QuitSettings(void);

int GetBrightness(void);
int GetVolume(void);

void SetRawBrightness(int value); // 0-255
void SetRawVolume(int value); // 0-160

void SetBrightness(int value); // -7..10 (below 0 = night steps)
int GetNightAlpha(void); // display-layer alpha for the current night step, 255 = none
void SetVolume(int value); // 0-20

int GetJack(void);
void SetJack(int value); // 0-1

int GetHDMI(void);
void SetHDMI(int value); // 0-1

int GetMute(void);

#endif  // __msettings_h__
