/*
 * Info.h
 *
 *  Created on: 18.01.2013
 *      Author: willms
 */

#ifndef INFO_H_
#define INFO_H_

class Info {
public:
	Info();
	virtual ~Info();
	virtual bool isInfoPending() = 0;

private:

};

#endif /* INFO_H_ */
