/*
 * led.cpp
 *
 *  Created on: 18.01.2013
 *      Author: willms
 */
#include <stdio.h>
#include "led.h"
#include "Logger.h"
#include <utils.h>
#include <unistd.h>
#include <string.h>

const std::string delay_on_fast = "100\n";
const std::string delay_off_fast = "100\n";
const std::string delay_on_slow = "499\n";
const std::string delay_off_slow = "499\n";

led::led(std::string ledName) {
	this->ledDirectory = "/sys/class/leds/";
	this->ledDirectory += ledName + "/";
}

led::~led() {
	// TODO !CodeTemplates.destructorstub.tododesc!
}

void led::LedOff() {
	std::string pathToFile = this->ledDirectory + "trigger";
	FILE* trigger = fopen(pathToFile.c_str(), "w");
	if (trigger == NULL) {
		LOG(Logger::LOG_ERROR, "%s kann nicht zugegriffen werden",
				pathToFile.c_str());
		return;
	}
	fwrite("none", 1, 4, trigger);
	fclose(trigger);
}

void led::LedOn() {
	std::string pathToFile = this->ledDirectory + "trigger";
	FILE* trigger = fopen(pathToFile.c_str(), "w");
	if (trigger == NULL) {
		LOG(Logger::LOG_ERROR, "%s kann nicht zugegriffen werden",
				pathToFile.c_str());
		return;
	}
	fwrite("default-on", 1, 10, trigger);
	fclose(trigger);
}

void led::LedFlashSlow() {


	std::string pathToDelayOnFile = this->ledDirectory + "delay_on";
	std::string pathToDelayOffFile = this->ledDirectory + "delay_off";
	if(getLedState() == led::LED_SLOW)
	{
		return;
	}
	timerOn();
	//sleep(2);
	FILE* delay_on = fopen(pathToDelayOnFile.c_str(), "w");
	FILE* delay_off = fopen(pathToDelayOffFile.c_str(), "w");
	if (delay_off == NULL) {
		LOG(Logger::LOG_ERROR, "%s kann nicht zugegriffen werden",
				pathToDelayOffFile.c_str());
		return;
	}
	if (delay_on == NULL) {
		LOG(Logger::LOG_ERROR, "%s kann nicht zugegriffen werden",
				pathToDelayOnFile.c_str());
		return;
	}
	fwrite(delay_off_slow.c_str(), 1, 4, delay_off);
	fwrite(delay_on_slow.c_str(), 1, 4, delay_on);

	fclose(delay_off);
	fclose(delay_on);
}

void led::LedFlashFast() {

	std::string pathToTriggerFile = this->ledDirectory + "trigger";
	std::string pathToDelayOnFile = this->ledDirectory + "delay_on";
	std::string pathToDelayOffFile = this->ledDirectory + "delay_off";
	if(getLedState() == led::LED_FAST)
	{
		return;
	}
	timerOn();

	//sleep(2);
	FILE* delay_on = fopen(pathToDelayOnFile.c_str(), "w");
	FILE* delay_off = fopen(pathToDelayOffFile.c_str(), "w");
	if (delay_off == NULL) {
		LOG(Logger::LOG_ERROR, "%s kann nicht zugegriffen werden",
				pathToDelayOffFile.c_str());
		return;
	}
	if (delay_on == NULL) {
		LOG(Logger::LOG_ERROR, "%s kann nicht zugegriffen werden",
				pathToDelayOnFile.c_str());
		return;
	}
	int count = fwrite(delay_off_fast.c_str(), 1, 4, delay_off);
	count = fwrite(delay_on_fast.c_str(), 1, 4, delay_on);

	fclose(delay_off);
	fclose(delay_on);
}
void led::timerOn() {
	std::string pathToTriggerFile = this->ledDirectory + "trigger";
	FILE* trigger = fopen(pathToTriggerFile.c_str(), "w");
	if (trigger == NULL) {
		LOG(Logger::LOG_ERROR, "%s kann nicht zugegriffen werden",
				pathToTriggerFile.c_str());
		return;
	}
	int count = fwrite("timer", 1, 6, trigger);
	fclose(trigger);

}

led::LedState led::getLedState() {
	char data[1024];
	size_t dataSize;
	LedState state = led::UNKNOWN;
	std::string pathToTriggerFile = this->ledDirectory + "trigger";
	FILE* trigger = fopen(pathToTriggerFile.c_str(), "r");
	if (trigger == NULL) {
		LOG(Logger::LOG_ERROR, "%s kann nicht zugegriffen werden",
				pathToTriggerFile.c_str());
		return led::UNKNOWN;
	}
	dataSize = fread(data, 1, 1024, trigger);
	if (dataSize > 0) {
		char *modeStart = NULL;
		char *modeEnd = NULL;
		modeStart = strchr(data,'[');
		modeEnd = strchr(data,']');
		if((modeStart == NULL) || (modeEnd == NULL)|| (modeStart > modeEnd))
		{
			return led::UNKNOWN;
		}
		*modeEnd = 0;
		std::string modeString = modeStart+1;
		if(strcmp(modeString.c_str(),"none")==0)
		{
			state = led::LED_OFF;
		}else if(strcmp(modeString.c_str(),"nand-disk")==0)
		{
		}else  if(strcmp(modeString.c_str(),"timer")==0)
		{
			state = checkDelayTimes();
		}else if(strcmp(modeString.c_str(),"default-on")==0)
		{
			state = led::LED_ON;
		}
	}
	fclose(trigger);
	return state;
}

led::LedState led::checkDelayTimes() {
	LedState state = led::UNKNOWN;
	std::string pathToDelayOnFile = this->ledDirectory + "delay_on";
	std::string pathToDelayOffFile = this->ledDirectory + "delay_off";
	char dataDelay_on[1024];
	char dataDelay_off[1024];
	FILE* delay_on = fopen(pathToDelayOnFile.c_str(), "r");
	if(delay_on == NULL)
	{
		return led::UNKNOWN;
	}
	FILE* delay_off = fopen(pathToDelayOffFile.c_str(), "r");
	if(delay_off == NULL)
	{
		fclose(delay_on);
		return led::UNKNOWN;
	}
	fread(dataDelay_off,1,1024,delay_off);
	fread(dataDelay_on,1,1024,delay_on);
	if(strstr((const char*)dataDelay_off,delay_off_fast.c_str())!=0 &&  strstr((const char*)dataDelay_on,delay_on_fast.c_str())!=0)
	{
		state = led::LED_FAST;
	}
	else if(strstr((const char*)dataDelay_off,delay_off_slow.c_str())!=0 &&  strstr((const char*)dataDelay_on,delay_on_slow.c_str())!=0)
	{
		state = led::LED_SLOW;
	}


	fclose(delay_off);
	fclose(delay_on);
	return state;
}
