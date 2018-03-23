#include "RFLGWInfoLED.h"
#include <XmlRpc.h>
#include <Logger.h>
#include <string>
#include <PropertyMap.h>

RFLGWInfoLED::RFLGWInfoLED() 
: rfLgwExists(false)
{
	rfLgwExists = isRfLgwPresent();
}

RFLGWInfoLED::~RFLGWInfoLED() {
}

void RFLGWInfoLED::ledOff()
{
	setLED(0);
}

void RFLGWInfoLED::ledOn()
{
	setLED(1);
}

void RFLGWInfoLED::ledFlashSlow()
{
	setLED(2);
}

void RFLGWInfoLED::ledFlashFast()
{
	setLED(3);
}

void RFLGWInfoLED::setLED(const unsigned int ledState)
{
	if(rfLgwExists) {
		std::string url("http://127.0.0.1:2001");
		XmlRpc::XmlRpcClient client(url);	
		XmlRpc::XmlRpcValue params;
		XmlRpc::XmlRpcValue result;
	
		params[0] = (int)ledState;
	
		bool success = client.execute("setRFLGWInfoLED", params, result);
		if ((!success) || (client.isFault()))
		{
			LOG(Logger::LOG_ERROR, "Error setting rf-lgw info led");
		}
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

