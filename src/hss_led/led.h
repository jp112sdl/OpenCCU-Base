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
			LED_OFF,
			LED_ON,
			LED_SLOW,
			LED_FAST,
			UNKNOWN,
		};
	led(std::string ledDirectory);
	virtual ~led();
	void LedOff();
	void LedOn();
	void LedFlashSlow();
	void LedFlashFast();
	LedState getLedState();
private:
	std::string ledDirectory;
	void timerOn();

	LedState checkDelayTimes();
};

#endif /* LED_H_ */
