#include "RFLGWInfoLED.h"
#include <XmlRpc.h>
#include <Logger.h>
#include <string>
#include <PropertyMap.h>
#include "led.h"

RFLGWInfoLED::RFLGWInfoLED() 
  : rfLgwExists(false),
    lastState(led::UNKNOWN)
{
	rfLgwExists = isRfLgwPresent();
}

RFLGWInfoLED::~RFLGWInfoLED() {
}

void RFLGWInfoLED::ledOff()
{
	setLED(led::LED_OFF);
}

void RFLGWInfoLED::ledOn()
{
	setLED(led::LED_ON);
}

void RFLGWInfoLED::ledFlashSlow()
{
	setLED(led::LED_SLOW);
}

void RFLGWInfoLED::ledFlashFast()
{
	setLED(led::LED_FAST);
}

void RFLGWInfoLED::setLED(led::LedState ledState)
{
	if(rfLgwExists) {
		std::string url("http://127.0.0.1:2001");
		XmlRpc::XmlRpcClient client(url);	
		XmlRpc::XmlRpcValue params;
		XmlRpc::XmlRpcValue result;
	
    switch(ledState)
    {
		  case led::LED_OFF:
        params[0] = 0;
      break;

      case led::LED_ON:
        params[0] = 1;
      break;

      case led::LED_SLOW:
        params[0] = 2;
      break;

      case led::LED_FAST:
        params[0] = 3;
      break;

      default:
        return;
      break;
    }
	
		bool success = client.execute("setRFLGWInfoLED", params, result);
		if ((!success) || (client.isFault()))
		{
			LOG(Logger::LOG_ERROR, "Error setting rf-lgw info led");
		}

    lastState = ledState;
	}
}

bool RFLGWInfoLED::isRfLgwPresent()
{
	const std::string confFilePath("/etc/config/rfd.conf");
	PropertyMap configData;
	if( (configData.ReadFromFile(confFilePath) < 0) ) {//try to read file
		return false;
	}
	PropertyMap::StringList sections=configData.ListSections();
    for(PropertyMap::StringList::iterator it=sections.begin();it!=sections.end();it++)
    {
        std::string& section=*it;
        if(section.find("Interface ")==0)
        {
            configData.SetCurrentSection(section);
            std::string type = configData.GetStringValue("Type", "");
			if(type.compare("HMLGW2") == 0) {
	        	return true;
	        }
	        else {
	        	continue;//next section
	        }
        }
    }
    return false;
}

led::LedState RFLGWInfoLED::getLedState() {
  return lastState;
}

void RFLGWInfoLED::switchLed(enum led::LedState state) {
  switch(state) {
    case led::LED_OFF:
      ledOff();
    break;
    case led::LED_ON:
      ledOn();
    break;
    case led::LED_SLOW:
      ledFlashSlow();
    break;
    case led::LED_FAST:
      ledFlashFast();
    break;
    default:
      // nothing
    break;
  }
}
