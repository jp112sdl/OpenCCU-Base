#ifndef _RFLGWINFOLED_H_
#define _RFLGWINFOLED_H_

class RFLGWInfoLED
{
public:
	RFLGWInfoLED();
	virtual ~RFLGWInfoLED();
	
	void ledOff();
	void ledOn();
	void ledFlashSlow();
	void ledFlashFast();
protected:
	virtual void setLED(const unsigned int ledState);
	virtual bool isRfLgwPresent();
	
private:
	bool rfLgwExists;
};

#endif
