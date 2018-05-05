/*
 * led.h
 *
 *  Created on: 18.01.2013
 *      Author: willms
 */

#ifndef LED_H_
#define LED_H_
#include <string>
#include <fcntl.h>
class led {
public:
	enum LedState
		{
			UNKNOWN=-1,
			LED_OFF,
			LED_ON,
			LED_SLOW,
			LED_FAST,
			LED_SLOW1,
			LED_FAST1,
		};
	led(std::string ledDirectory);
	virtual ~led();
	void LedOff();
	void LedOn();
	void LedFlashSlow(int cycle=0);
	void LedFlashFast(int cycle=0);
	LedState getLedState();
  void switchLed(enum LedState state);
private:
	std::string ledDirectory;
	void timerOn();

	LedState checkDelayTimes();
};

#endif /* LED_H_ */
