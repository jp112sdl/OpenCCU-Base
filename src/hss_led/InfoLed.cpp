/*
 * InfoLed.cpp
 *
 *  Created on: 18.01.2013
 *      Author: willms
 */

#include "InfoLed.h"
#include <utils.h>

InfoLed::InfoLed():infoLed("info"),
infoLedRefreshTime(120000),
nextInfoUpdate(0),
service(),
alarm(),
update(),
parser(),
rflgwInfoLed(){
	infoLed.LedOff();
}

InfoLed::~InfoLed() {
	// TODO !CodeTemplates.destructorstub.tododesc!
}

void InfoLed::updateLedState() {
	led::LedState newState = led::LED_OFF;
	led::LedState oldState = led::UNKNOWN;
	if(this->service.isInfoPending() || this->update.isInfoPending())
	{
		newState = led::LED_SLOW;
	}
	if(this->alarm.isInfoPending())
	{
		newState = led::LED_FAST;
	}
	oldState = this->infoLed.getLedState();
	if((newState != oldState)|(this->nextInfoUpdate > time_millis())) {
		switch (newState) {
		case led::LED_OFF:
			this->infoLed.LedOff();
			this->rflgwInfoLed.ledOff();
			break;
		case led::LED_ON:
			this->infoLed.LedOn();
			this->rflgwInfoLed.ledOn();
			break;
		case led::LED_SLOW:
			this->infoLed.LedFlashSlow();
			this->rflgwInfoLed.ledFlashSlow();
			break;
		case led::LED_FAST:
			this->infoLed.LedFlashFast();
			this->rflgwInfoLed.ledFlashFast();
			break;
		default:
			this->infoLed.LedOff();
			this->rflgwInfoLed.ledOff();
			break;
		}
		this->nextInfoUpdate = time_millis() + this->infoLedRefreshTime;
	}
}

bool InfoLed::checkMessage(std::string& msg) {
	bool ret = parser.parsMessage(msg);
	if(ret)
	{
		switch(parser.getCommandType())
		{
		case SERVICE:
			this->service.setMessage(parser.getMessageSource(),parser.getServiceValue());
			break;
		case ALARM:
			this->alarm.setMessage(parser.getMessageSource(),parser.getAlarmValue());
			break;
		default:
			break;
		}
	}
	return ret;
}
