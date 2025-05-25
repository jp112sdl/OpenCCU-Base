#include "HS485Frame.h"

HS485Frame::HS485Frame(void)
{
	type_index=9;
}

HS485Frame::~HS485Frame(void)
{
}

std::string HS485Frame::GetPayload()
{
    std::string payload;
    for(unsigned int i=9;i<GetSize();i++)payload.append(1, GetByteData(i));
    return payload;
}

void HS485Frame::SetPayload(const std::string& s)
{
    Resize(9+s.size());
    for(unsigned int i=0;i<s.size();i++)SetByteData(i+9, s[i]);
}

uint32_t HS485Frame::GetSenderAddress()
{
    return GetIntValue(FIELD_SENDER);
}

uint32_t HS485Frame::GetReceiverAddress()
{
    return GetIntValue(FIELD_RECEIVER);
}

void HS485Frame::SetSenderAddress(uint32_t address)
{
    SetIntValue(FIELD_SENDER, address);
}

void HS485Frame::SetReceiverAddress(uint32_t address)
{
    SetIntValue(FIELD_RECEIVER, address);
}

void HS485Frame::SetCtrl(int ctrl)
{
    SetIntValue(FIELD_CTRL, ctrl);
}

int HS485Frame::GetCtrl()
{
    return GetIntValue(FIELD_CTRL);
}
