/*
 * AlarmMessage.cpp
 *
 *  Created on: 18.01.2013
 *      Author: willms
 */

#include "AlarmMessage.h"

AlarmMessage::AlarmMessage() {
	// TODO Automatisch generierter Konstruktorstub

}

AlarmMessage::~AlarmMessage() {
	// TODO !CodeTemplates.destructorstub.tododesc!
}

bool AlarmMessage::isInfoPending() {
	std::map<std::string,bool>::iterator it;
	for(it = messages.begin();it != messages.end();++it)
	{
		if(it->second)
		{
			return true;
		}
	}

	return false;
}

void AlarmMessage::setMessage(std::string source, bool value) {
	messages[source] = value;
}
